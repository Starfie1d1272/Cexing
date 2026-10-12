package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	logrus "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v3"
)

const controllerSecretFile = "controller-security/secret"
const maxConfigBytes = 16 * 1024 * 1024

var (
	controllerSecret  string
	secretMu          sync.RWMutex
	controllerSession string // readiness challenge, never a credential
	activeOverrides   string // accessed under runLock
)

func init() {
	// Register runs inside Mihomo's authenticated group. Exact routes replace
	// embedded PUT/PATCH handlers without modifying dependency source.
	route.Register(func(r chi.Router) {
		session := controllerSession
		r.Get("/ohos/session", func(w MHTTP.ResponseWriter, req *MHTTP.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"session": session})
		})
		for _, path := range []string{"/configs", "/configs/"} {
			r.Put(path, reloadPlatformConfig)
			r.Patch(path, patchPlatformConfig)
		}
		// Host exec/core replacement and UI downloads belong to app lifecycle.
		for _, path := range []string{"/restart", "/restart/", "/restart/*", "/upgrade", "/upgrade/", "/upgrade/*"} {
			r.HandleFunc(path, func(w MHTTP.ResponseWriter, req *MHTTP.Request) {
				controllerError(w, 405, "operation belongs to the VPN host")
			})
		}
	})
}

// Go is the sole writer; app processes read the same private 0700/0600 file.
// This protects against other app UIDs, not a compromised process of this app.
// Profiles, Settings, IPC Wants and saved YAML never carry this credential.
func initControllerSecurity(home string) error {
	dir := filepath.Join(home, "controller-security")
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return errors.New("controller: cannot create private credential directory")
	}
	st, err := os.Lstat(dir)
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		return errors.New("controller: invalid private credential directory")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return errors.New("controller: cannot protect credential directory")
	}
	path := filepath.Join(home, controllerSecretFile)
	secret := ""
	st, err = os.Lstat(path)
	if os.IsNotExist(err) {
		bytes := make([]byte, 32)
		if _, err := rand.Read(bytes); err != nil {
			return errors.New("controller: secure random unavailable")
		}
		secret = hex.EncodeToString(bytes)
		f, err := os.CreateTemp(dir, ".secret-")
		if err != nil {
			return errors.New("controller: cannot persist credential")
		}
		temp := f.Name()
		defer os.Remove(temp)
		_, writeErr := f.WriteString(secret)
		syncErr := f.Sync()
		closeErr := f.Close()
		if writeErr != nil || syncErr != nil || closeErr != nil {
			return errors.New("controller: cannot persist credential")
		}
		if err := os.Rename(temp, path); err != nil {
			return errors.New("controller: cannot persist credential")
		}
	} else {
		if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o077 != 0 || st.Size() != 64 {
			return errors.New("controller: invalid private credential file")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return errors.New("controller: cannot read credential")
		}
		secret = string(data)
	}
	decoded, err := hex.DecodeString(secret)
	if err != nil || len(decoded) != 32 || hex.EncodeToString(decoded) != secret {
		return errors.New("controller: invalid credential; refusing unauthenticated startup")
	}
	secretMu.Lock()
	controllerSecret = secret
	secretMu.Unlock()
	logrus.SetOutput(controllerLogWriter{})
	return nil
}

func redactControllerSecret(text string) string {
	secretMu.RLock()
	defer secretMu.RUnlock()
	if controllerSecret != "" {
		return strings.ReplaceAll(text, controllerSecret, "[REDACTED]")
	}
	return text
}

type controllerLogWriter struct{}

func (controllerLogWriter) Write(p []byte) (int, error) {
	_, err := io.WriteString(os.Stdout, redactControllerSecret(string(p)))
	return len(p), err
}

// Mandatory last layer after subscription and supported user overrides.
// Do not persist this map: it contains a credential.
func enforcePlatformSecurity(overlay map[string]any) {
	overlay["external-controller"] = defaultController
	for _, key := range []string{"external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-doh-server", "external-ui-url", "external-ui-name"} {
		overlay[key] = ""
	}
	overlay["external-controller-routing-mark"] = 0
	overlay["external-controller-cors"] = map[string]any{"allow-origins": []string{"http://" + defaultController}, "allow-private-network": false}
	overlay["secret"] = controllerSecret
	overlay["external-ui"] = "ui"
	overlay["tun"] = map[string]any{"enable": false}
	overlay["iptables"] = map[string]any{"enable": false}
	if ntp, ok := overlay["ntp"].(map[string]any); ok {
		ntp["write-to-system"] = false
	}
}

func preparePlatformConfig(text, overrides string) (*config.Config, error) {
	if controllerSecret == "" {
		return nil, errors.New("controller: credential unavailable")
	}
	if len(text) > maxConfigBytes {
		return nil, errors.New("configuration exceeds size limit")
	}
	overlay := map[string]any{}
	if err := yaml.Unmarshal([]byte(sanitizeConfigJson(text)), &overlay); err != nil || overlay == nil {
		return nil, errors.New("mihomoStartTun: parse configJson failed; reimport UTF-8 YAML")
	}
	// Generic listeners can also create TUN devices; disabling only raw.tun
	// is insufficient. Reject this alternate path instead of silently dropping it.
	if listeners, ok := overlay["listeners"].([]any); ok {
		for _, item := range listeners {
			if listener, ok := item.(map[string]any); ok {
				if kind, ok := listener["type"].(string); ok && strings.EqualFold(kind, "tun") {
					return nil, errors.New("platform prohibits additional TUN listeners")
				}
			}
		}
	}
	applyOverrides(overlay, overrides)
	applyPlatformDefaults(overlay)
	enforcePlatformSecurity(overlay)
	buf, err := yaml.Marshal(overlay)
	if err != nil {
		return nil, errors.New("configuration cannot be encoded")
	}
	raw := config.DefaultRawConfig()
	if err := yaml.Unmarshal(buf, raw); err != nil {
		return nil, errors.New("configuration has invalid field types")
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return nil, errors.New("configuration validation failed")
	}
	return cfg, nil // never return arbitrary YAML values / credentials in errors
}

func validateUIRoot() error {
	root := filepath.Join(homeDir, "ui")
	if _, err := os.Lstat(root); os.IsNotExist(err) {
		return nil
	}
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.Type()&os.ModeSymlink != 0 || (!entry.IsDir() && !entry.Type().IsRegular()) {
			return errors.New("controller: UI must contain only app-owned files, no symlinks")
		}
		return nil
	})
}

func startController() error {
	if err := validateUIRoot(); err != nil {
		return err
	}
	challenge := make([]byte, 16)
	if _, err := rand.Read(challenge); err != nil {
		return errors.New("controller: secure random unavailable")
	}
	controllerSession = hex.EncodeToString(challenge)
	route.SetUIPath(filepath.Join(homeDir, "ui"))
	// hub.ApplyConfig derives debug/alternate transports from subscription.
	// Keep one authenticated server, with unauthenticated /debug disabled.
	route.ReCreateServer(&route.Config{Addr: defaultController, Secret: controllerSecret, IsDebug: false,
		Cors: route.Cors{AllowOrigins: []string{"http://" + defaultController}}})
	client := &http.Client{Timeout: 200 * time.Millisecond, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, "http://"+defaultController+"/ohos/session", nil)
		req.Header.Set("Authorization", "Bearer "+controllerSecret)
		resp, err := client.Do(req)
		if err == nil {
			var result struct {
				Session string `json:"session"`
			}
			decodeErr := json.NewDecoder(io.LimitReader(resp.Body, 1024)).Decode(&result)
			resp.Body.Close()
			if resp.StatusCode == 200 && decodeErr == nil && result.Session == controllerSession {
				return nil
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	route.ReCreateServer(&route.Config{})
	return errors.New("controller: authenticated listener unavailable")
}
func stopController() { route.ReCreateServer(&route.Config{}) }
func controllerError(w MHTTP.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": message})
}

func reloadPlatformConfig(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var body struct {
		Path      string  `json:"path"`
		Payload   string  `json:"payload"`
		Overrides *string `json:"overrides"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, maxConfigBytes+1))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF || (body.Path == "") == (body.Payload == "") {
		controllerError(w, 400, "provide one configuration path or payload")
		return
	}
	text := body.Payload
	if body.Path != "" {
		// Confine reads to app configuration files and reject symlink paths.
		path, err := filepath.EvalSymlinks(body.Path)
		rel, relErr := filepath.Rel(homeDir, path)
		ext := strings.ToLower(filepath.Ext(path))
		if err != nil || relErr != nil || !filepath.IsAbs(body.Path) || path != filepath.Clean(body.Path) || rel == "." || strings.HasPrefix(rel, "..") || strings.HasPrefix(rel, "controller-security/") || strings.HasPrefix(rel, "ui/") || (ext != ".yaml" && ext != ".yml" && ext != ".json") {
			controllerError(w, 400, "configuration path is outside allowed app files")
			return
		}
		st, statErr := os.Lstat(path)
		if statErr != nil || !st.Mode().IsRegular() {
			controllerError(w, 400, "configuration must be a regular file")
			return
		}
		file, err := os.Open(path)
		if err != nil {
			controllerError(w, 400, "configuration file unavailable")
			return
		}
		stat, statErr := file.Stat()
		if statErr != nil || !stat.Mode().IsRegular() {
			file.Close()
			controllerError(w, 400, "configuration must be a regular file")
			return
		}
		data, err := io.ReadAll(io.LimitReader(file, maxConfigBytes+1))
		file.Close()
		if err != nil {
			controllerError(w, 400, "configuration file unavailable")
			return
		}
		text = string(data)
	}
	runLock.Lock()
	defer runLock.Unlock()
	if !initialized {
		controllerError(w, 409, "core is not initialized")
		return
	}
	overrides := activeOverrides
	if body.Overrides != nil {
		overrides = *body.Overrides
	}
	cfg, err := preparePlatformConfig(text, overrides)
	if err != nil {
		controllerError(w, 400, err.Error())
		return
	}
	// executor does not recreate Controller; system-fd TUN stays host-owned.
	executor.ApplyConfig(cfg, true)
	activeOverrides = overrides
	w.WriteHeader(MHTTP.StatusNoContent)
}

func patchPlatformConfig(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	values := map[string]string{}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 4096))
	if decoder.Decode(&values) != nil || decoder.Decode(new(any)) != io.EOF || len(values) == 0 {
		controllerError(w, 400, "invalid settings patch")
		return
	}
	for key, value := range values {
		switch key {
		case "mode":
			if _, ok := tunnel.ModeMapping[value]; !ok {
				controllerError(w, 400, "invalid mode")
				return
			}
		case "log-level":
			if _, ok := log.LogLevelMapping[value]; !ok {
				controllerError(w, 400, "invalid log level")
				return
			}
		default:
			controllerError(w, 400, "only mode and log-level may be patched")
			return
		}
	}
	runLock.Lock()
	defer runLock.Unlock()
	if value, ok := values["mode"]; ok {
		tunnel.SetMode(tunnel.ModeMapping[value])
	}
	if value, ok := values["log-level"]; ok {
		log.SetLevel(log.LogLevelMapping[value])
	}
	w.WriteHeader(MHTTP.StatusNoContent)
}
