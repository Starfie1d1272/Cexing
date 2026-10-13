package configpipeline

import (
	"context"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestSmartAutoConvertsOnlyAutomaticGroupsAfterMerge(t *testing.T) {
	const original = `proxies:
  - {name: a, type: direct}
  - {name: b, type: direct}
proxy-groups:
  - {name: automatic, type: url-test, proxies: [a, b], tolerance: 40}
  - {name: balance, type: load-balance, proxies: [a, b], strategy: round-robin}
  - {name: manual, type: select, proxies: [automatic, balance, DIRECT]}
  - {name: fallback, type: fallback, proxies: [a, b]}
rules: ["MATCH,manual"]
`
	const overlay = `proxy-groups:
  - {name: automatic, type: url-test, proxies: [b, a], tolerance: 30}
  - {name: balance, type: load-balance, proxies: [a, b], strategy: round-robin}
  - {name: manual, type: select, proxies: [automatic, balance, DIRECT]}
  - {name: fallback, type: fallback, proxies: [a, b]}
rules: ["MATCH,manual"]
`
	c := Compiler{Platform: func(context.Context, *yaml.Node) error { return nil },
		Validate: func(context.Context, []byte) error { return nil }}
	request := Request{Original: []byte(original), Overlays: [][]byte{[]byte(overlay)}, Strategy: SmartAuto}
	converted, err := c.Compile(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := yaml.Unmarshal(converted.YAML, &doc); err != nil {
		t.Fatal(err)
	}
	groups := doc["proxy-groups"].([]any)
	auto := groups[0].(map[string]any)
	balance := groups[1].(map[string]any)
	if auto["type"] != "smart" || auto["uselightgbm"] != true || auto["tolerance"] != 30 ||
		!equalMembers(auto["proxies"], "b", "a") || balance["type"] != "smart" ||
		balance["strategy"] != nil || balance["collectdata"] != false || balance["prefer-asn"] != false {
		t.Fatal("automatic group conversion lost policy or ordered members")
	}
	if groups[2].(map[string]any)["type"] != "select" || groups[3].(map[string]any)["type"] != "fallback" ||
		!equalMembers(groups[2].(map[string]any)["proxies"], "automatic", "balance", "DIRECT") ||
		!equalMembers(doc["rules"], "MATCH,manual") {
		t.Fatal("manual selection or rule references changed")
	}
	without, err := c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{[]byte(overlay)}})
	if err != nil || !strings.Contains(string(without.YAML), "type: url-test") ||
		!strings.Contains(string(without.YAML), "type: load-balance") {
		t.Fatal("disabled conversion did not restore source and Merge types", err)
	}
	if strings.Contains(string(converted.Original), "uselightgbm") || string(converted.Original) != original {
		t.Fatal("original subscription changed")
	}
}

func equalMembers(value any, expected ...string) bool {
	items, ok := value.([]any)
	if !ok || len(items) != len(expected) {
		return false
	}
	for i, item := range items {
		if item != expected[i] {
			return false
		}
	}
	return true
}
