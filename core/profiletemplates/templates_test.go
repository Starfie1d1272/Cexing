package profiletemplates

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"

	"core/configpipeline"
	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor"
	"gopkg.in/yaml.v3"
)

const fixture = `proxies:
  - {name: US-one, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}
proxy-groups:
  - {name: Pick, type: select, proxies: [US-one], x-advanced: preserved}
rules: ["DOMAIN,example.test,DIRECT", "MATCH,Pick"]
x-advanced: {future: [one, two]}
`

func compile(source string, p Plan, validate configpipeline.Validator) (configpipeline.Result, error) {
	return (configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: validate}).Compile(context.Background(), configpipeline.Request{
		Original: []byte(source), Strategy: func(ctx context.Context, root *yaml.Node) error { return Apply(ctx, root, p) },
	})
}
func accept(context.Context, []byte) error { return nil }

func TestTemplatesUseFreshSourceAndPreserveUnknown(t *testing.T) {
	p := Plan{TemplateID: "ai", Version: Version, TargetGroup: "Pick"}
	first, err := compile(fixture, p, accept)
	if err != nil {
		t.Fatal(err)
	}
	again, err := compile(fixture, p, accept)
	if err != nil || !bytes.Equal(first.YAML, again.YAML) {
		t.Fatal("fresh-source compilation not deterministic", err)
	}
	if !bytes.Equal(first.Original, []byte(fixture)) {
		t.Fatal("original modified")
	}
	var doc yaml.Node
	if err = yaml.Unmarshal(first.YAML, &doc); err != nil {
		t.Fatal(err)
	}
	root := doc.Content[0]
	if field(root, "x-advanced") == nil || field(field(root, "proxy-groups").Content[0], "x-advanced") == nil {
		t.Fatal("unknown fields lost")
	}
	rules := field(root, "rules").Content
	if rules[len(rules)-1].Value != "MATCH,Pick" || rules[len(rules)-2].Value != "DOMAIN,example.test,DIRECT" {
		t.Fatal("upstream ordering changed")
	}
	updated := strings.Replace(fixture, "example.test", "updated.test", 1)
	next, err := compile(updated, p, accept)
	if err != nil || !strings.Contains(string(next.YAML), "updated.test") {
		t.Fatal("subscription update frozen", err)
	}
	original, err := compile(updated, Plan{TemplateID: "original", Version: Version}, accept)
	if err != nil || strings.Contains(string(original.YAML), "chatgpt.com") {
		t.Fatal("disable failed", err)
	}
	if strings.Count(string(next.YAML), "DOMAIN-SUFFIX,chatgpt.com,") != 1 {
		t.Fatal("duplicate owned rules")
	}
}

func TestTemplateFailsClosedAndAutomaticIsExplicit(t *testing.T) {
	for _, p := range []Plan{
		{TemplateID: "ai", Version: 2, TargetGroup: "Pick"},
		{TemplateID: "ai", Version: 1, TargetGroup: "missing"},
		{TemplateID: "ai", Version: 1, TargetGroup: "Pick,DIRECT"},
		{TemplateID: "automatic", Version: 1, TargetGroup: "Pick"},
		{TemplateID: "original", Version: 1, ReplaceRules: true},
	} {
		if _, err := compile(fixture, p, accept); err == nil {
			t.Fatalf("accepted invalid plan %#v", p)
		}
	}
	auto, err := compile(fixture, Plan{TemplateID: "automatic", Version: 1, TargetGroup: "Pick", ReplaceRules: true}, accept)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(auto.YAML), "example.test") || !strings.Contains(string(auto.YAML), "MATCH,Pick") {
		t.Fatal("automatic rules not replaced")
	}
	empty := strings.Replace(fixture, "proxies: [US-one]", "proxies: []", 1)
	if _, err = compile(empty, Plan{TemplateID: "ai", Version: 1, TargetGroup: "Pick"}, accept); err == nil {
		t.Fatal("empty target accepted")
	}
}

// The fixed parser has process-global side effects. Validate in a disposable
// process and use inline providers; no subscription URL or network download.
func TestLockedParserTemplates(t *testing.T) {
	if os.Getenv("CEXING_TEMPLATE_PARSER_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestLockedParserTemplates$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_TEMPLATE_PARSER_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("locked parser: %v\n%s", err, out)
		}
		return
	}
	validator := func(_ context.Context, b []byte) error { _, err := config.Parse(b); return err }
	for _, p := range []Plan{
		{TemplateID: "original", Version: 1},
		{TemplateID: "ai", Version: 1, TargetGroup: "Pick"},
		{TemplateID: "automatic", Version: 1, TargetGroup: "Pick", ReplaceRules: true},
		{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "region", Selector: "Pick", Enable: true}},
	} {
		if _, err := compile(fixture, p, validator); err != nil {
			t.Fatalf("%s: %v", p.TemplateID, err)
		}
	}
	provider := `proxy-providers:
  feed:
    type: inline
    payload: [{name: one, type: ss, server: 192.0.2.2, port: 443, cipher: aes-128-gcm, password: synthetic}]
proxy-groups: [{name: Pick, type: select, use: [feed]}]
rules: ['MATCH,Pick']
`
	if _, err := compile(provider, Plan{TemplateID: "ai", Version: 1, TargetGroup: "Pick"}, validator); err != nil {
		t.Fatal(err)
	}
}
