package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

func TestOfflineProviderUsesLocalCacheWithoutFetching(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := initControllerSecurity(home); err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	url := server.URL + "/feed"
	constant.SetHomeDir(home)
	cache := constant.Path.Resolve(constant.Path.GetPathByHash("proxies", url))
	if err := os.MkdirAll(filepath.Dir(cache), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("proxies: [{name: one, type: socks5, server: 192.0.2.1, port: 1080}]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	config := "proxy-providers:\n  cached:\n    type: http\n    url: " + url + "\nproxy-groups:\n  - {name: pick, type: select, use: [cached]}\nrules: ['MATCH,pick']\n"
	first, err := coreValidateOfflineWithReceipt(home, config, "")
	if err != nil || first == "" {
		t.Fatalf("cached provider rejected: %v", err)
	}
	if requests.Load() != 0 {
		t.Fatal("fetched provider")
	}
	custom := "proxy-providers:\n  cached:\n    type: http\n    path: providers/custom.yaml\n    url: " + url + "\nproxy-groups:\n  - {name: pick, type: select, use: [cached]}\nrules: ['MATCH,pick']\n"
	if _, err := coreValidateOfflineWithReceipt(home, custom, ""); err == nil || err.Error() != "PROVIDER_UNRESOLVED" {
		t.Fatalf("unbound custom cache accepted: %v", err)
	}
	if err := os.WriteFile(cache, []byte("proxies: [{name: two, type: socks5, server: 192.0.2.2, port: 1080}]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	second, err := coreValidateOfflineWithReceipt(home, config, "")
	if err != nil || first == second {
		t.Fatal("cache revision not detected")
	}
	if err := os.Remove(cache); err != nil {
		t.Fatal(err)
	}
	if _, err := coreValidateOfflineWithReceipt(home, config, ""); err == nil || err.Error() != "PROVIDER_UNRESOLVED" {
		t.Fatalf("missing cache accepted: %v", err)
	}
}
