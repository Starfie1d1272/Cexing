package configpipeline

import (
	"context"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const regionFixture = `proxies:
  - {name: "HK Alpha", type: ss, server: hk.example.test, port: 443, cipher: aes-128-gcm, password: fake}
  - {name: "JP Beta", type: ss, server: jp.example.test, port: 443, cipher: aes-128-gcm, password: fake}
  - {name: "mystery", type: ss, server: unknown.example.test, port: 443, cipher: aes-128-gcm, password: fake}
proxy-groups:
  - {name: Main, type: select, proxies: ["HK Alpha", "JP Beta", mystery]}
rules:
  - DOMAIN,example.test,Main
  - MATCH,Main
`

func TestRegionPreviewAndRuleTarget(t *testing.T) {
	root, err := RegionMergedSource([]byte(regionFixture), nil)
	if err != nil {
		t.Fatal(err)
	}
	preview, err := PreviewRegion(root, "Main", map[string]string{"mystery": "日本"})
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Eligible || preview.Counts["日本"] != 2 || preview.Counts["香港"] != 1 || preview.Unknown != 0 {
		t.Fatalf("unexpected preview: %+v", preview)
	}
	plan := RegionPlan{Mode: "region", Selector: "Main", Enable: true,
		Assignments: map[string]string{"mystery": "日本"}}
	if err := ApplyRegion(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	if err := validateReferences(root); err != nil {
		t.Fatal(err)
	}
	got, _ := yaml.Marshal(root)
	if !strings.Contains(string(got), "DOMAIN,example.test,Cexing Smart Main") ||
		!strings.Contains(string(got), "MATCH,Cexing Smart Main") ||
		!strings.Contains(string(got), "empty-fallback: REJECT") {
		t.Fatalf("generated rule/fallback mismatch: %s", got)
	}
	if err := ApplyRegion(context.Background(), root, plan); err == nil {
		t.Fatal("applying to generated output must not duplicate groups")
	}
}

func TestRegionProviderPendingAndNoConversion(t *testing.T) {
	text := strings.Replace(regionFixture, `proxies: ["HK Alpha", "JP Beta", mystery]`,
		`proxies: ["HK Alpha", "JP Beta", mystery], use: [remote]`, 1)
	text += "proxy-providers:\n  remote: {type: file, path: cached-provider.yaml}\n"
	root, err := RegionMergedSource([]byte(text), nil)
	if err != nil {
		t.Fatal(err)
	}
	p, err := PreviewRegion(root, "Main", nil)
	if err != nil {
		t.Fatal(err)
	}
	if p.Eligible || !p.ProviderPending {
		t.Fatalf("provider should be pending: %+v", p)
	}
	if err := ApplyRegion(context.Background(), root, RegionPlan{Mode: "all", Selector: "Main"}); err == nil {
		t.Fatal("unresolved provider plan accepted")
	}
	root, err = RegionMergedSource([]byte(regionFixture), []byte("proxy-groups:\n  - {name: Main, type: select, proxies: [HK Alpha, JP Beta, mystery]}\n  - {name: Auto, type: url-test, proxies: [HK Alpha, JP Beta], url: 'http://www.gstatic.com/generate_204', interval: 300}\n"))
	if err != nil {
		t.Fatal(err)
	}
	p, err = PreviewRegion(root, "Main", nil)
	if err != nil {
		t.Fatal(err)
	}
	if p.Offerable {
		t.Fatal("existing convertible group must suppress first-import offer")
	}
}

func TestRegionCreateLeavesOriginalRules(t *testing.T) {
	root, err := RegionMergedSource([]byte(regionFixture), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := ApplyRegion(context.Background(), root, RegionPlan{Mode: "all", Selector: "Main"}); err != nil {
		t.Fatal(err)
	}
	got, _ := yaml.Marshal(root)
	if !strings.Contains(string(got), "MATCH,Main") || strings.Contains(string(got), "MATCH,Cexing Smart Main") {
		t.Fatalf("create rewrote rule: %s", got)
	}
}
