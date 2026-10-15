package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"core/configpipeline"
	"github.com/metacubex/mihomo/constant"
	"gopkg.in/yaml.v3"
)

func TestRegionProviderSnapshotIsLocalAndFiltered(t *testing.T) {
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	if err := os.MkdirAll(filepath.Join(home, "providers"), 0700); err != nil {
		t.Fatal(err)
	}
	cache := `proxies:
  - {name: "HK cached", type: direct}
  - {name: "JP cached", type: direct}
`
	if err := os.WriteFile(filepath.Join(home, "providers", "region.yaml"), []byte(cache), 0600); err != nil {
		t.Fatal(err)
	}
	source := `proxies:
  - {name: "SG explicit", type: direct}
proxy-providers:
  local: {type: file, path: providers/region.yaml}
proxy-groups:
  - {name: Main, type: select, proxies: ["SG explicit"], use: [local], filter: "HK|JP"}
rules: ["MATCH,Main"]
`
	root, err := configpipeline.RegionMergedSource([]byte(source), nil)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := regionProviderNames(home, root)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(resolved["local"], ",") != "HK cached,JP cached" {
		t.Fatalf("bad snapshot: %v", resolved)
	}
	preview, err := configpipeline.PreviewRegionWithProviders(root, "Main", nil, resolved)
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Eligible || preview.ProviderPending || len(preview.Nodes) != 3 || preview.Counts["新加坡"] != 1 {
		t.Fatalf("bad provider preview: %+v", preview)
	}
	plan := configpipeline.RegionPlan{Mode: "region", Selector: "Main", ResolvedProviders: resolved}
	if err := configpipeline.ApplyRegion(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	generated, _ := yaml.Marshal(root)
	if !strings.Contains(string(generated), "use:\n") || !strings.Contains(string(generated), "filter: ^(?:HK cached)$") ||
		!strings.Contains(string(generated), "MATCH,Main") {
		t.Fatalf("provider/rule generation mismatch: %s", generated)
	}
	includeAll := `proxies:
  - {name: "SG explicit", type: direct}
  - {name: "US auto", type: direct}
proxy-providers:
  inline: {type: inline, payload: [{name: "HK inline", type: direct}, {name: "JP inline", type: direct}]}
proxy-groups:
  - {name: Main, type: select, proxies: ["SG explicit"], include-all: true, filter: "HK|US", exclude-filter: "US"}
rules: ["MATCH,Main"]
`
	allRoot, err := configpipeline.RegionMergedSource([]byte(includeAll), nil)
	if err != nil {
		t.Fatal(err)
	}
	allResolved, err := regionProviderNames(home, allRoot)
	if err != nil {
		t.Fatal(err)
	}
	allPreview, err := configpipeline.PreviewRegionWithProviders(allRoot, "Main", nil, allResolved)
	if err != nil {
		t.Fatal(err)
	}
	if !allPreview.Eligible || len(allPreview.Nodes) != 2 || allPreview.Counts["新加坡"] != 1 ||
		allPreview.Counts["香港"] != 1 {
		t.Fatalf("include-all/filter classification mismatch: %+v", allPreview)
	}
	if err := configpipeline.ApplyRegion(context.Background(), allRoot,
		configpipeline.RegionPlan{Mode: "all", Selector: "Main", ResolvedProviders: allResolved}); err != nil {
		t.Fatal(err)
	}
	allGenerated, _ := yaml.Marshal(allRoot)
	if _, _, err := configpipeline.InspectOffline(allGenerated); err != nil {
		t.Fatalf("include-all generated a broken reference or cycle: %v", err)
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	address := server.URL + "/feed"
	constant.SetHomeDir(home)
	httpCache := constant.Path.Resolve(constant.Path.GetPathByHash("proxies", address))
	if err := os.MkdirAll(filepath.Dir(httpCache), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(httpCache, []byte(cache), 0600); err != nil {
		t.Fatal(err)
	}
	httpSource := strings.Replace(source, "type: file, path: providers/region.yaml",
		"type: http, url: '"+address+"'", 1)
	httpRoot, err := configpipeline.RegionMergedSource([]byte(httpSource), nil)
	if err != nil {
		t.Fatal(err)
	}
	httpNames, err := regionProviderNames(home, httpRoot)
	if err != nil || len(httpNames["local"]) != 2 || requests.Load() != 0 {
		t.Fatalf("HTTP cache was not used offline: %v, names=%v, requests=%d", err, httpNames, requests.Load())
	}
	if err := os.Remove(filepath.Join(home, "providers", "region.yaml")); err != nil {
		t.Fatal(err)
	}
	if _, err := regionProviderNames(home, root); err == nil {
		t.Fatal("missing provider cache accepted")
	}
}

func TestRoutingProviderScopeExcludesBuiltinDirectAndDNS(t *testing.T) {
	home := t.TempDir()
	root, err := configpipeline.LayeredMergeSource([]byte(`proxy-providers:
  local: {type: inline, payload: [{name: JP proxy, type: socks5, server: node.example.test, port: 1080}, {name: HK direct, type: direct}, {name: JP dns, type: dns}]}
`), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	names, err := regionProviderNames(home, root, true)
	if err != nil || strings.Join(names["local"], ",") != "JP proxy" {
		t.Fatal("routing included non-proxy provider entries", err)
	}
}
