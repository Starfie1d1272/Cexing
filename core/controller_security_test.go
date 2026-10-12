package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
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
	if err := os.Mkdir(filepath.Join(home, "ui"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "ui", "index.html"), []byte("offline-panel"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfgText := `mixed-port: 0
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
	if cfg.Controller.ExternalController != defaultController || cfg.Controller.Secret != secret || cfg.Controller.ExternalControllerTLS != "" || cfg.Controller.ExternalControllerUnix != "" || cfg.Controller.ExternalControllerPipe != "" || cfg.Controller.ExternalDohServer != "" || cfg.Controller.ExternalUI != "ui" || cfg.Controller.ExternalUIURL != "" || cfg.Controller.ExternalUIName != "" || cfg.General.Tun.Enable || cfg.Controller.Cors.AllowPrivateNetwork || len(cfg.Controller.Cors.AllowOrigins) != 1 || cfg.Controller.Cors.AllowOrigins[0] != "http://"+defaultController {
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
	if code, body := request("GET", "/ui/", "", ""); code != 200 || !strings.Contains(body, "offline-panel") {
		t.Fatal("static UI must be separate from API auth")
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
	body, _ := json.Marshal(map[string]string{"path": file})
	if code, _ := request("PUT", "/configs?force=true", bearer, string(body)); code != 204 {
		t.Fatalf("safe reload rejected: %d", code)
	}
	if tunnel.Mode() != tunnel.Direct || listener.GetTunConf().Enable || executor.GetGeneral().MixedPort != 0 {
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
