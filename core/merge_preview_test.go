package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func requireMergePreviewFields(t *testing.T, data []byte) {
	t.Helper()
	var preview struct {
		Digest  string           `json:"digest"`
		Changes []map[string]any `json:"changes"`
	}
	if err := json.Unmarshal(data, &preview); err != nil || preview.Digest == "" || len(preview.Changes) == 0 {
		t.Fatal("missing merge preview", err)
	}
	for _, change := range preview.Changes {
		section, sectionOK := change["section"].(string)
		_, beforeOK := change["before"].(float64)
		_, afterOK := change["after"].(float64)
		if !sectionOK || section == "" || !beforeOK || !afterOK || change["contentChanged"] != true || change["kind"] == nil {
			t.Fatal("merge preview fields do not match the ArkTS contract", change)
		}
	}
}

func TestMergePreviewUsesPinnedDialectWithoutLeakingValues(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	base := `proxies:
  - {name: private-node, type: socks5, server: 192.0.2.1, port: 1080}
proxy-groups:
  - {name: pick, type: select, proxies: [private-node]}
rules: ["MATCH,pick"]
dns: {enable: false, nameserver: [192.0.2.53]}
`
	merge := `proxy-groups:
  - {name: pick, type: select, proxies: [DIRECT]}
hosts: {synthetic.example: 192.0.2.3}
`
	first, err := corePreviewMerge(home, base, merge, "")
	if err != nil {
		t.Fatal(err)
	}
	requireMergePreviewFields(t, []byte(first))
	second, err := corePreviewMerge(home, base, merge, "")
	if err != nil || first != second {
		t.Fatal("preview is not deterministic")
	}
	if strings.Contains(first, "private-node") || strings.Contains(first, "192.0.2") || !strings.Contains(first, "proxy-groups") || !strings.Contains(first, "hosts") {
		t.Fatal("preview missing fixed sections or leaking config values")
	}
	if _, err := corePreviewMerge(home, base, "secret: prohibited", ""); err == nil {
		t.Fatal("secret overlay accepted")
	}
}
