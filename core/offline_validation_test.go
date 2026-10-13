package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestOfflineValidationUsesCoreWithoutApplying(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	valid := `proxies:
  - {name: node, type: socks5, server: 192.0.2.1, port: 1080}
proxy-groups:
  - {name: pick, type: select, proxies: [node]}
rules:
  - MATCH,pick
`
	if err := coreValidateOffline(home, valid, ""); err != nil {
		t.Fatalf("valid synthetic candidate: %v", err)
	}
	if initialized || tunListener != nil {
		t.Fatal("validation started the core")
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	for name, text := range map[string]string{
		"syntax":      "proxies: [",
		"reference":   "proxies: [{name: node, type: socks5, server: 192.0.2.1, port: 1080}]\nproxy-groups: [{name: pick, type: select, proxies: [absent]}]",
		"provider":    "proxy-providers: {remote: {type: http, url: '" + server.URL + "/synthetic'}}",
		"protected":   "secret: subscription-secret\n" + valid,
		"core-schema": "proxies: [{name: node, type: missing-protocol, server: 192.0.2.1, port: 1080}]",
	} {
		if err := coreValidateOffline(home, text, ""); err == nil {
			t.Errorf("%s unexpectedly accepted", name)
		}
	}
	if requests.Load() != 0 {
		t.Fatal("validation fetched a provider")
	}
}
