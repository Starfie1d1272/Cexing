package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
