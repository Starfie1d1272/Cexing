package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVersionStagePreservesResourceFailureWithoutPublishing(t *testing.T) {
	home := t.TempDir()
	original := "proxies: [{name: synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\nrules: ['MATCH,DIRECT']\n"
	input, err := json.Marshal(versionAction{Op: "stage", ProfileID: "private-name.yaml", Original: original, Metadata: `{}`})
	if err != nil {
		t.Fatal(err)
	}
	result := coreVersionAction(home, string(input))
	if !strings.Contains(result, `"error":"RESOURCE_MISSING"`) {
		t.Fatalf("resource cause collapsed: %s", result)
	}
	if _, err := os.Stat(filepath.Join(home, "profile-versions", "state.json")); !os.IsNotExist(err) {
		t.Fatal("failed stage published state")
	}
	bundle := coreDiagnosticAction(home, `{"op":"diagnostics-export"}`)
	var exported any
	if err := json.Unmarshal([]byte(bundle), &exported); err != nil {
		t.Fatal(err)
	}
	compact, err := json.Marshal(exported)
	if err != nil {
		t.Fatal(err)
	}
	bundle = string(compact)
	for _, value := range []string{`"operation":"profile"`, `"stage":"configuration_prepare"`, `"code":"RESOURCE_MISSING"`} {
		if !strings.Contains(bundle, value) {
			t.Fatalf("missing structured evidence %s", value)
		}
	}
	if strings.Contains(bundle, "private-name") || strings.Contains(bundle, "192.0.2.1") {
		t.Fatal("profile source leaked")
	}
}

func TestVersionStagePreservesUnresolvedProviderCategory(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := "proxy-providers: {synthetic: {type: http, url: 'http://127.0.0.1:9/synthetic', path: './providers/synthetic.yaml'}}\nproxy-groups: [{name: pick, type: select, use: [synthetic]}]\nrules: ['MATCH,pick']\n"
	result, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: "synthetic.yaml", Original: original, Metadata: `{}`})
	if err == nil || err.Error() != "PROVIDER_UNRESOLVED" || result.Version != nil {
		t.Fatalf("provider cause collapsed or candidate published: %v", err)
	}
}
