package main

// Optional real Controller fixture for scripts/test-zashboard-browser.py.
// No TUN, proxy listener, DNS server, credentials or system network settings are used.
import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
)

func TestZashboardBrowserFixture(t *testing.T) {
	assets := os.Getenv("ZASHBOARD_BROWSER_ASSETS")
	ready := os.Getenv("ZASHBOARD_BROWSER_READY")
	if assets == "" || ready == "" {
		t.Skip("optional browser fixture")
	}
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	data, err := os.ReadFile(filepath.Join(assets, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Version string `json:"version"`
		Files   []struct {
			Path string `json:"path"`
		} `json:"files"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	versionDir := filepath.Join(home, "ui", "versions", manifest.Version)
	if err := os.MkdirAll(versionDir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, item := range manifest.Files {
		if !uiAssetPathPattern.MatchString(item.Path) || filepath.IsAbs(item.Path) || strings.Contains(item.Path, "..") {
			t.Fatal("unsafe fixture path")
		}
		bytes, err := os.ReadFile(filepath.Join(assets, item.Path))
		if err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(versionDir, item.Path)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, bytes, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(versionDir, "manifest.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	entry := fmt.Sprintf(`<!doctype html><!--ZASHBOARD_SELECTION:{"current":"%s","previous":""}--><meta charset="utf-8"><title>Zashboard</title><script>location.replace('./versions/%s/' + location.hash)</script>`, manifest.Version, manifest.Version)
	if err := os.WriteFile(filepath.Join(home, "ui", "index.html"), []byte(entry), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := preparePlatformConfig(`mixed-port: 0
mode: rule
log-level: silent
dns:
  enable: false
proxy-groups:
  - name: Local test
    type: select
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
`, `{"mixedPort":0}`)
	if err != nil {
		t.Fatal(err)
	}
	if err := startController(); err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	activeOverrides = `{"mixedPort":0}`
	bytes, _ := json.Marshal(map[string]string{"secret": controllerSecret, "version": manifest.Version})
	if err := os.WriteFile(ready, bytes, 0600); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(4 * time.Minute)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(ready + ".stop"); err == nil {
			return
		}
		if _, err := os.Stat(ready + ".restart"); err == nil {
			if err := os.Remove(ready + ".restart"); err != nil {
				t.Fatal(err)
			}
			coreStop()
			time.Sleep(500 * time.Millisecond)
			if err := coreInit(home); err != nil {
				t.Fatal(err)
			}
			if err := startController(); err != nil {
				t.Fatal(err)
			}
			executor.ApplyConfig(cfg, true)
			activeOverrides = `{"mixedPort":0}`
			if err := os.WriteFile(ready+".restarted", []byte("ready"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("browser fixture deadline exceeded")
}
