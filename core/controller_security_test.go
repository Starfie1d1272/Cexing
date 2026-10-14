package main

import (
	"context"
	"core/configpipeline"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/coder/websocket"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// All inputs and credentials in this suite are disposable test fixtures.
func TestControllerSecurity(t *testing.T) {
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	secret := controllerSecret
	st, err := os.Stat(filepath.Join(home, controllerSecretFile))
	if err != nil || st.Mode().Perm() != 0o600 || len(secret) != 64 {
		t.Fatal("credential must be 256-bit hex in a 0600 file")
	}
	if err := initControllerSecurity(home); err != nil || controllerSecret != secret {
		t.Fatal("credential must survive reinitialization")
	}
	if strings.Contains(redactControllerSecret("Bearer "+secret), secret) {
		t.Fatal("log redaction failed")
	}
	version := seedSyntheticPanel(t, home)
	cfgText := `mixed-port: 0
bind-address: 127.0.0.1
mode: direct
log-level: debug
external-controller: 0.0.0.0:9191
external-controller-tls: 0.0.0.0:9192
external-controller-unix: /tmp/not-the-app.sock
external-controller-pipe: ignored
secret: subscription-controlled
external-doh-server: /unauthenticated-doh
external-ui: /tmp
external-ui-url: https://invalid.example/ui.zip
external-ui-name: ../../private
external-controller-cors:
  allow-origins: ['*']
  allow-private-network: true
tun:
  enable: true
  auto-route: true
  file-descriptor: 9876
  address: 10.0.0.1/8
  mtu: 1500
dns:
  enable: false
`
	cfg, err := preparePlatformConfig(cfgText, `{"mixedPort":0,"secret":"override-controlled","external-controller":"0.0.0.0:9193"}`)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Controller.ExternalController != defaultController || cfg.Controller.Secret != secret || cfg.Controller.ExternalControllerTLS != "" || cfg.Controller.ExternalControllerUnix != "" || cfg.Controller.ExternalControllerPipe != "" || cfg.Controller.ExternalDohServer != "" || cfg.Controller.ExternalUI != "" || cfg.Controller.ExternalUIURL != "" || cfg.Controller.ExternalUIName != "" || cfg.General.Tun.Enable || cfg.Controller.Cors.AllowPrivateNetwork || len(cfg.Controller.Cors.AllowOrigins) != 1 || cfg.Controller.Cors.AllowOrigins[0] != "http://"+defaultController {
		t.Fatal("subscription or overrides escaped platform constraints")
	}
	if err := startController(); err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	activeOverrides = `{"mixedPort":0}`
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	request := func(method, path, auth, body string) (int, string) {
		t.Helper()
		req, err := http.NewRequest(method, "http://"+defaultController+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), secret) {
			t.Fatal("response exposed credential")
		}
		return resp.StatusCode, string(data)
	}
	bearer := "Bearer " + secret
	for _, auth := range []string{"", "Bearer wrong", secret} {
		if code, _ := request("GET", "/version", auth, ""); code != 401 {
			t.Fatalf("unauthorized status %d", code)
		}
	}
	if code, _ := request("GET", "/version", bearer, ""); code != 200 {
		t.Fatalf("authorized status %d", code)
	}
	if code, body := request("GET", "/ui/", "", ""); code != 200 || !strings.Contains(body, "ZASHBOARD_SELECTION") {
		t.Fatal("static UI must be separate from API auth")
	}
	if code, body := request("GET", "/ui/versions/"+version+"/", "", ""); code != 200 || !strings.Contains(body, "offline-panel") {
		t.Fatal("verified selected UI asset must be served")
	}
	if code, _ := request("GET", "/debug/pprof/", "", ""); code != 404 {
		t.Fatalf("debug exposed: %d", code)
	}
	if code, _ := request("GET", "/unauthenticated-doh", "", ""); code != 404 {
		t.Fatalf("DoH exposed: %d", code)
	}
	for _, endpoint := range []string{"/restart", "/restart/", "/upgrade", "/upgrade/", "/upgrade/ui", "/upgrade/geo", "/upgrade/future"} {
		if code, _ := request("POST", endpoint, "", ""); code != 401 {
			t.Fatalf("auth bypass on %s: %d", endpoint, code)
		}
		if code, _ := request("POST", endpoint, bearer, ""); code != 405 {
			t.Fatalf("dangerous operation %s: %d", endpoint, code)
		}
	}
	for _, endpoint := range []string{"/configs", "/configs/"} {
		if code, _ := request("PATCH", endpoint, bearer, `{"tun":{"enable":true}}`); code != 400 {
			t.Fatal("TUN PATCH accepted")
		}
		if code, _ := request("PATCH", endpoint, bearer, `{"mode":"global"}`); code != 204 {
			t.Fatal("safe mode PATCH rejected")
		}
	}
	if tunnel.Mode() != tunnel.Global {
		t.Fatal("PATCH did not update mode")
	}
	wsRead := func(query, auth string, want int) *websocket.Conn {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		header := http.Header{}
		if auth != "" {
			header.Set("Authorization", auth)
		}
		conn, resp, err := websocket.Dial(ctx, "ws://"+defaultController+"/traffic"+query, &websocket.DialOptions{HTTPClient: client, HTTPHeader: header})
		if want != 101 {
			if err == nil || resp == nil || resp.StatusCode != want {
				t.Fatalf("WS auth rejection expected %d", want)
			}
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		_, data, err := conn.Read(ctx)
		if err != nil || !json.Valid(data) || strings.Contains(string(data), secret) {
			t.Fatal("authenticated WS did not deliver safe traffic JSON")
		}
		return conn
	}
	wsRead("", "", 401)
	wsRead("?token=wrong", "", 401)
	ws := wsRead("", bearer, 101)
	defer ws.CloseNow()
	browserWS := wsRead("?token="+secret, "", 101)
	browserWS.CloseNow()
	// Reload the hostile profile through the real Controller. No TUN/system VPN
	// is created by this host test. Verify active overrides and existing WS survive.
	file := filepath.Join(home, "synthetic.yaml")
	if err := os.WriteFile(file, []byte(cfgText), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Run("REST cannot grant or replace host network authorization", func(t *testing.T) {
		before := activeOverrides
		for _, override := range []string{`{"allowLan":true}`, `{"allowLan":[]}`, `{"allowLan":{}}`, `{"mixedPort":28009}`} {
			body, _ := json.Marshal(map[string]string{"payload": cfgText, "overrides": override})
			if code, _ := request("PUT", "/configs", bearer, string(body)); code != 400 {
				t.Fatalf("network override accepted: %s status=%d", override, code)
			}
			if activeOverrides != before || executor.GetGeneral().AllowLan {
				t.Fatal("rejected request changed host authorization")
			}
		}
		// Model confirmed native startup. Omitted network fields must preserve
		// its policy, including when the panel changes unrelated settings.
		activeOverrides = `{"mixedPort":0,"allowLan":true}`
		body, _ := json.Marshal(map[string]string{"payload": cfgText, "overrides": `{"logLevel":"info"}`})
		if code, _ := request("PUT", "/configs", bearer, string(body)); code != 204 || !executor.GetGeneral().AllowLan || listener.BindAddress() != "*" {
			t.Fatal("reload lost native LAN consent")
		}
		body, _ = json.Marshal(map[string]string{"payload": cfgText, "overrides": `{"allowLan":false}`})
		if code, _ := request("PUT", "/configs", bearer, string(body)); code != 400 {
			t.Fatal("panel changed native LAN policy")
		}
		// Model the next native session after disabling or legacy migration.
		activeOverrides = before
	})
	t.Run("reload-session-and-byte-boundaries", func(t *testing.T) {
		stale, _ := json.Marshal(map[string]string{"payload": "mixed-port: 0\nmode: direct\ndns: {enable: false}\n", "expectedSession": controllerSession + "-stale"})
		if code, _ := request("PUT", "/configs", bearer, string(stale)); code != 409 {
			t.Fatal("old session request accepted", code)
		}
		priorTimeout := client.Timeout
		client.Timeout = 30 * time.Second
		defer func() { client.Timeout = priorTimeout }()
		prefix := "proxies: [{name: synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\nrules: ['MATCH,DIRECT']\nx-data: "
		exact := prefix + strings.Repeat("a", maxConfigBytes-len(prefix))
		encoded, _ := json.Marshal(map[string]string{"payload": exact, "expectedSession": controllerSession})
		if len(encoded) <= maxConfigBytes+1 {
			t.Fatal("fixture did not exceed old JSON cap")
		}
		if code, _ := request("PUT", "/configs", bearer, string(encoded)); code != 204 {
			t.Fatal("16 MiB decoded YAML rejected", code)
		}
		excess, _ := json.Marshal(map[string]string{"payload": exact + "a", "expectedSession": controllerSession})
		if code, _ := request("PUT", "/configs", bearer, string(excess)); code != 400 {
			t.Fatal("oversize decoded YAML accepted", code)
		}
		if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
			t.Fatal(err)
		}
		original := prefix + strings.Repeat("\\", 9*1024*1024) + "\n"
		result, _, err := compilePinnedMerge(home, original, "", `{"mixedPort":0}`)
		if err != nil {
			t.Fatal("large compile", err)
		}
		if len(result.YAML) > maxConfigBytes {
			t.Fatal("fixture generated too much YAML")
		}
		result.ProfileID = "large.yaml"
		result.Metadata = "{}"
		store := configpipeline.FileStore{Root: filepath.Join(home, "profile-versions")}
		staged, err := store.Stage(context.Background(), result)
		if err != nil {
			t.Fatal(err)
		}
		candidate, err := os.ReadFile(staged.Path)
		if err != nil {
			t.Fatal(err)
		}
		escaped, _ := json.Marshal(map[string]string{"payload": string(candidate), "expectedSession": controllerSession})
		if len(escaped) <= maxConfigBytes+1 {
			t.Fatal("fixture lacks escape expansion")
		}
		if code, _ := request("PUT", "/configs", bearer, string(escaped)); code != 204 {
			t.Fatal("compile-stage-HTTP escape boundary rejected", code)
		}
		if err = store.Discard(context.Background(), staged); err != nil {
			t.Fatal(err)
		}
	})
	body, _ := json.Marshal(map[string]string{"path": file})
	if code, _ := request("PUT", "/configs?force=true", bearer, string(body)); code != 204 {
		t.Fatalf("safe reload rejected: %d", code)
	}
	if tunnel.Mode() != tunnel.Direct || listener.GetTunConf().Enable || executor.GetGeneral().MixedPort != 0 || listener.BindAddress() != "127.0.0.1" {
		t.Fatal("reload failed to reapply final platform/setting constraints")
	}
	if code, _ := request("GET", "/version", "", ""); code != 401 {
		t.Fatal("reload lost authentication")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, _, err = ws.Read(ctx)
	cancel()
	if err != nil {
		t.Fatal("reload interrupted existing WS")
	}
	reconnect := wsRead("", bearer, 101)
	reconnect.CloseNow()
	for _, payload := range []string{
		`{"payload":"[broken"}`, `{"payload":"{}"} {"ignored":"tail"}`, `{"payload":"listeners: [{type: tun, name: extra-tun}]"}`, `{"payload":"mode: impossible"}`, `{"path":"/etc/passwd"}`,
		`{"path":"` + filepath.Join(home, controllerSecretFile) + `"}`, `{"payload":"{}","secret":"escape"}`,
	} {
		if code, _ := request("PUT", "/configs", bearer, payload); code != 400 {
			t.Fatalf("unsafe reload accepted: %s", payload)
		}
	}
	t.Run("rejected-reload-keeps-log-policy", func(t *testing.T) {
		previousOverrides := activeOverrides
		defer func() { activeOverrides = previousOverrides }()
		defer setLogToFile(true)
		for _, enabled := range []bool{true, false} {
			setLogToFile(enabled)
			body, _ := json.Marshal(map[string]string{
				"payload":   "mode: impossible",
				"overrides": fmt.Sprintf(`{"logToFile":%t}`, !enabled),
			})
			if code, _ := request("PUT", "/configs", bearer, string(body)); code != 400 {
				t.Fatalf("invalid configuration status %d", code)
			}
			logFileMu.Lock()
			actual := logToFileEnabled
			logFileMu.Unlock()
			if actual != enabled {
				t.Fatal("HTTP 400 changed the active log-file policy")
			}
		}
		body, _ := json.Marshal(map[string]string{"payload": "mixed-port: 0\nmode: direct\ndns: {enable: false}", "overrides": `{"logToFile":false}`})
		if code, _ := request("PUT", "/configs", bearer, string(body)); code != 204 {
			t.Fatal("valid log policy reload rejected")
		}
		logFileMu.Lock()
		actual := logToFileEnabled
		logFileMu.Unlock()
		if actual {
			t.Fatal("accepted reload did not commit the log-file policy")
		}
	})
	t.Run("provider-credential-paths", func(t *testing.T) {
		secretPath := filepath.Join(home, controllerSecretFile)
		before, err := os.ReadFile(secretPath)
		if err != nil {
			t.Fatal(err)
		}
		aliasDir := filepath.Join(home, "provider-alias")
		if err := os.Symlink(filepath.Dir(secretPath), aliasDir); err != nil {
			t.Fatal(err)
		}
		aliasFile := filepath.Join(home, "provider-hardlink")
		if err := os.Link(secretPath, aliasFile); err != nil {
			t.Fatal(err)
		}
		for _, section := range []string{"proxy-providers", "rule-providers"} {
			for _, kind := range []string{"http", "file"} {
				for _, path := range []string{"controller-security", controllerSecretFile, "cache/../" + controllerSecretFile, secretPath, filepath.Dir(secretPath), "provider-alias/secret", aliasFile, "../outside.yaml"} {
					provider := map[string]any{"type": kind, "path": path, "url": "http://127.0.0.1:1/synthetic", "behavior": "domain", "format": "yaml"}
					text, _ := yaml.Marshal(map[string]any{"mixed-port": 0, "dns": map[string]any{"enable": false}, section: map[string]any{"synthetic": provider}})
					body, _ := json.Marshal(map[string]string{"payload": string(text)})
					if code, _ := request("PUT", "/configs", bearer, string(body)); code != 400 {
						t.Fatalf("%s %s unsafe path %q status %d", section, kind, path, code)
					}
				}
			}
			for _, path := range []string{"", "providers/synthetic.yaml", filepath.Join(home, "providers", "synthetic.yaml")} {
				provider := map[string]any{"type": "http", "path": path, "url": "http://127.0.0.1:1/synthetic", "behavior": "domain", "format": "yaml"}
				text, _ := yaml.Marshal(map[string]any{"mixed-port": 0, "dns": map[string]any{"enable": false}, section: map[string]any{"synthetic": provider}})
				if _, err := preparePlatformConfig(string(text), ""); err != nil {
					t.Fatalf("normal %s path %q rejected: %v", section, path, err)
				}
			}
			prefix := "proxies"
			if section == "rule-providers" {
				prefix = "rules"
			}
			if err := os.Symlink(filepath.Dir(secretPath), filepath.Join(home, prefix)); err != nil {
				t.Fatal(err)
			}
			text, _ := yaml.Marshal(map[string]any{section: map[string]any{"synthetic": map[string]any{"type": "http", "url": "http://127.0.0.1:1/synthetic"}}})
			if _, err := preparePlatformConfig(string(text), ""); err == nil {
				t.Fatal("default provider cache followed directory alias")
			}
			if err := os.Remove(filepath.Join(home, prefix)); err != nil {
				t.Fatal(err)
			}
		}
		after, err := os.ReadFile(secretPath)
		if err != nil || string(after) != string(before) {
			t.Fatal("rejected provider changed credentials")
		}
		t.Log("32 authenticated unsafe provider reloads rejected; credential bytes unchanged; six normal HTTP cache paths accepted")
	})
	if tunnel.Mode() != tunnel.Direct {
		t.Fatal("invalid reload changed running configuration")
	}
	link := filepath.Join(home, "symlink.yaml")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	body, _ = json.Marshal(map[string]string{"path": link})
	if code, _ := request("PUT", "/configs", bearer, string(body)); code != 400 {
		t.Fatal("symlink reload accepted")
	}
	if err := os.Symlink(file, filepath.Join(home, "ui", "escape.yaml")); err != nil {
		t.Fatal(err)
	}
	if validateUIRoot() == nil {
		t.Fatal("UI symlink accepted")
	}
	for _, scenario := range []string{"missing", "corrupt-selector", "corrupt-asset", "old-version-symlink", "root-symlink", "root-file", "missing-selected-version", "unexpected-file"} {
		t.Run("ui-degradation/"+scenario, func(t *testing.T) {
			ui := filepath.Join(home, "ui")
			if err := os.RemoveAll(ui); err != nil {
				t.Fatal(err)
			}
			version := seedSyntheticPanel(t, home)
			switch scenario {
			case "missing":
				if err := os.RemoveAll(ui); err != nil {
					t.Fatal(err)
				}
			case "corrupt-selector":
				if err := os.WriteFile(filepath.Join(ui, "index.html"), []byte("corrupt selector"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "corrupt-asset":
				if err := os.WriteFile(filepath.Join(ui, "versions", version, "index.html"), []byte("corrupt bytes"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "old-version-symlink":
				old := filepath.Join(ui, "versions", strings.Repeat("f", 64))
				if err := os.Mkdir(old, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(home, controllerSecretFile), filepath.Join(old, "unused-link")); err != nil {
					t.Fatal(err)
				}
			case "root-symlink":
				if err := os.RemoveAll(ui); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(home, "controller-security"), ui); err != nil {
					t.Fatal(err)
				}
			case "root-file":
				if err := os.RemoveAll(ui); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(ui, []byte("corrupt root"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "missing-selected-version":
				if err := os.RemoveAll(filepath.Join(ui, "versions", version)); err != nil {
					t.Fatal(err)
				}
			case "unexpected-file":
				if err := os.WriteFile(filepath.Join(ui, "versions", version, "unexpected.txt"), []byte("do not serve"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			// Actual coreStartTun reaches its real TUN constructor, after init,
			// Controller readiness and ApplyConfig. Deliberately invalid fd stops
			// here; no device or system VPN is created or changed by this test.
			err := coreStartTun(2147483647, "mixed-port: 0\nmode: direct\ndns: {enable: false}\n", `{"mixedPort":0}`)
			if err == nil || !strings.HasPrefix(err.Error(), "mihomoStartTun: start tun:") {
				t.Fatalf("bad UI blocked VPN initialization before TUN boundary: %v", err)
			}
			for _, path := range []string{"/ui/", "/ui/index.html", "/ui/secret", "/ui/%2e%2e/controller-security/secret", "/ui/versions/" + strings.Repeat("f", 64) + "/unused-link"} {
				if code, _ := request("GET", path, "", ""); code != 404 {
					t.Fatalf("unsafe static request %s returned %d", path, code)
				}
			}
			if code, _ := request("GET", "/version", "", ""); code != 401 {
				t.Fatal("bad UI bypassed API authentication")
			}
			if code, _ := request("GET", "/version", bearer, ""); code != 200 {
				t.Fatal("bad UI disabled authenticated API")
			}
			if code, body := request("GET", "/ohos/ui-status", bearer, ""); code != 200 || !strings.Contains(body, `"available":false`) {
				t.Fatal("missing UI recovery status")
			}
			if scenario == "old-version-symlink" {
				conn := wsRead("", bearer, 101)
				conn.CloseNow()
				if code, _ := request("PUT", "/configs", bearer, `{"payload":"mixed-port: 0\nexternal-ui: controller-security\ndns: {enable: false}"}`); code != 204 {
					t.Fatal("bad UI blocked reload")
				}
				if code, _ := request("GET", "/ui/secret", "", ""); code != 404 {
					t.Fatal("reload restored unsafe static root")
				}
			}
		})
	}
	if err := os.RemoveAll(filepath.Join(home, "ui")); err != nil {
		t.Fatal(err)
	}
	seedSyntheticPanel(t, home)
	if err := startController(); err != nil {
		t.Fatal(err)
	}
	if code, body := request("GET", "/ohos/ui-status", bearer, ""); code != 200 || !strings.Contains(body, `"available":true`) {
		t.Fatal("valid UI did not recover on next Controller initialization")
	}
	t.Run("synchronous-controller-lifecycle", func(t *testing.T) {
		// Go beyond the independent review's failure at cycle 12. Each round
		// has a real authenticated WS, immediate stop, and immediate port rebind.
		for cycle := 0; cycle < 16; cycle++ {
			if err := startController(); err != nil {
				t.Fatalf("cycle %d start: %v", cycle+1, err)
			}
			old := wsRead("", bearer, 101)
			stopController()
			probe, err := net.Listen("tcp4", defaultController)
			if err != nil {
				t.Fatalf("cycle %d stop did not release port: %v", cycle+1, err)
			}
			probe.Close()
			if socket, err := net.DialTimeout("tcp4", defaultController, 200*time.Millisecond); err == nil {
				socket.Close()
				t.Fatalf("cycle %d stopped listener still accepts", cycle+1)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_, _, readErr := old.Read(ctx)
			writeErr := old.Write(ctx, websocket.MessageText, []byte("after-stop"))
			cancel()
			old.CloseNow()
			if readErr == nil || writeErr == nil {
				t.Fatalf("cycle %d old WS survived stop (read=%v, write=%v)", cycle+1, readErr, writeErr)
			}
		}
		t.Log("16 real Controller/WS cycles: immediate stop released port, rejected TCP and closed old WS reads/writes")
		if err := startController(); err != nil {
			t.Fatal(err)
		}
		if code, _ := request("GET", "/version", bearer, ""); code != 200 {
			t.Fatal("final fresh session API failed")
		}
		fresh := wsRead("", bearer, 101)
		fresh.CloseNow()
	})
	t.Run("generic-inbound-stop-and-restart", func(t *testing.T) {
		reserved, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := reserved.Addr().String()
		port := reserved.Addr().(*net.TCPAddr).Port
		reserved.Close()
		text := fmt.Sprintf("mixed-port: 0\ndns: {enable: false}\nlisteners:\n- name: synthetic-http\n  type: http\n  listen: 127.0.0.1\n  port: %d\n", port)
		apply := func() {
			cfg, err := preparePlatformConfig(text, `{"mixedPort":0}`)
			if err != nil {
				t.Fatal(err)
			}
			executor.ApplyConfig(cfg, true)
		}
		for round := 0; round < 2; round++ {
			apply()
			conn, err := net.DialTimeout("tcp4", address, time.Second)
			if err != nil {
				t.Fatal("generic HTTP did not open", err)
			}
			conn.Close()
			coreStop()
			if conn, err := net.DialTimeout("tcp4", address, 200*time.Millisecond); err == nil {
				conn.Close()
				t.Fatal("generic HTTP still accepts new TCP after coreStop")
			}
			probe, err := net.Listen("tcp4", address)
			if err != nil {
				t.Fatal("generic HTTP port not released", err)
			}
			probe.Close()
		}
		t.Log("generic inbound is separate from Controller: accepts before stop, rejects/rebinds immediately after stop, reopens on fresh ApplyConfig")
	})
	t.Run("silent-log-handler-cleanup", func(t *testing.T) {
		if err := startController(); err != nil {
			t.Fatal(err)
		}
		dial := func(path string) *websocket.Conn {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			conn, _, err := websocket.Dial(ctx, "ws://"+defaultController+path, &websocket.DialOptions{HTTPClient: client, HTTPHeader: http.Header{"Authorization": []string{bearer}}})
			if err != nil {
				t.Fatal(err)
			}
			return conn
		}
		first := dial("/logs?level=silent")
		waitLogHandlers(t, true)
		first.CloseRead(context.Background()) // Ping requires a client reader to process pong
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		if err := first.Ping(ctx); err != nil {
			cancel()
			t.Fatal("log WS ping/pong failed", err)
		}
		cancel()
		first.CloseNow()
		waitLogHandlers(t, false) // no emitted logs required to wake silent stream
		second := dial("/logs?level=silent")
		waitLogHandlers(t, true)
		stopController()
		if controllerLogHandlersPresent() {
			t.Fatal("stop returned with log handler or reader/relay still alive")
		}
		ctx, cancel = context.WithTimeout(context.Background(), time.Second)
		_, _, err := second.Read(ctx)
		cancel()
		second.CloseNow()
		if err == nil {
			t.Fatal("silent WS survived stop")
		}
		if err := startController(); err != nil {
			t.Fatal(err)
		}
		restarted := dial("/logs?level=silent")
		waitLogHandlers(t, true)
		restarted.CloseNow()
		waitLogHandlers(t, false)
		// Legacy and structured wire shapes remain compatible and secrets redacted.
		for _, format := range []string{"", "&format=structured"} {
			conn := dial("/logs?level=info" + format)
			waitLogHandlers(t, true)
			marker := "synthetic-log-plain"
			if format != "" {
				marker = "synthetic-log-structured"
			}
			log.Infoln("%s %s", marker, secret)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_, data, err := conn.Read(ctx)
			cancel()
			conn.CloseNow()
			waitLogHandlers(t, false)
			if err != nil || !json.Valid(data) || !strings.Contains(string(data), marker) || strings.Contains(string(data), secret) || !strings.Contains(string(data), "[REDACTED]") {
				t.Fatal("log wire format or redaction failed")
			}
		}
		t.Log("silent peer-close and stop release handler, reader/relay and subscription without log events; fresh log WS and both formats succeed")
	})
}

func controllerLogStack() string {
	buffer := make([]byte, 512*1024)
	size := runtime.Stack(buffer, true)
	return string(buffer[:size])
}
func controllerLogHandlersPresent() bool {
	stack := controllerLogStack()
	return strings.Contains(stack, "hub/route.getLogs(") || strings.Contains(stack, "core.getControllerLogs")
}
func waitLogHandlers(t *testing.T, present bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		stack := controllerLogStack()
		if present {
			// A direct event-channel wait proves Subscribe has completed, rather
			// than merely observing the HTTP upgrade still in progress.
			if strings.Contains(stack, " [select]:\ncore.getControllerLogs(") || strings.Contains(stack, " [chan receive]:\ngithub.com/metacubex/mihomo/hub/route.getLogs(") {
				return
			}
		} else if !controllerLogHandlersPresent() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("log handler/reader/relay presence did not become %v", present)
}

func seedSyntheticPanel(t *testing.T, home string) string {
	t.Helper()
	content := []byte("offline-panel")
	files := []uiAssetEntry{{Path: "index.html", Size: int64(len(content)), SHA256: uiSHA256(content)}}
	identity, err := json.Marshal(files)
	if err != nil {
		t.Fatal(err)
	}
	version := uiSHA256(identity)
	directory := filepath.Join(home, "ui", "versions", version)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest, err := json.Marshal(uiAssetManifest{Schema: 1, Version: version, SourceSHA: strings.Repeat("a", 40), Files: files})
	if err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string][]byte{filepath.Join(directory, "index.html"): content, filepath.Join(directory, "manifest.json"): manifest, filepath.Join(home, "ui", "index.html"): uiSelectionEntry(uiSelection{Current: version})} {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return version
}

func TestPersistentProjectionExcludesSecret(t *testing.T) {
	overlay := map[string]any{"secret": "synthetic-source-credential", "external-controller": "0.0.0.0:9393"}
	projectPlatformConfig(overlay)
	data, err := yaml.Marshal(overlay)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := overlay["secret"]; exists || strings.Contains(string(data), "synthetic-source-credential") || strings.Contains(string(data), "secret:") {
		t.Fatal("persistent projection included credential")
	}
	if overlay["external-controller"] != defaultController {
		t.Fatal("persistent projection missed shared platform constraint")
	}
}

func TestCredentialStorageFailsClosed(t *testing.T) {
	for _, kind := range []string{"corrupt", "world-readable", "symlink-directory", "symlink-file"} {
		t.Run(kind, func(t *testing.T) {
			home := t.TempDir()
			dir := filepath.Join(home, "controller-security")
			if kind == "symlink-directory" {
				if err := os.Symlink(t.TempDir(), dir); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.Mkdir(dir, 0o700); err != nil {
					t.Fatal(err)
				}
				path := filepath.Join(dir, "secret")
				if kind == "symlink-file" {
					if err := os.Symlink(filepath.Join(t.TempDir(), "secret"), path); err != nil {
						t.Fatal(err)
					}
				} else {
					content := "bad"
					mode := os.FileMode(0o600)
					if kind == "world-readable" {
						content = strings.Repeat("a", 64)
						mode = 0o644
					}
					if err := os.WriteFile(path, []byte(content), mode); err != nil {
						t.Fatal(err)
					}
					if err := os.Chmod(path, mode); err != nil {
						t.Fatal(err)
					}
				}
			}
			if initControllerSecurity(home) == nil {
				t.Fatal("invalid credential store did not fail closed")
			}
		})
	}
}
