package formeditstest

import (
	"bytes"
	"context"
	"core/configpipeline"
	"encoding/json"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	_ "github.com/metacubex/mihomo/hub/executor"
	"gopkg.in/yaml.v3"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Disposable parser child: production form operations -> locked compiler/parser
// -> actual rule Match. No listeners, device, provider download or private input.
func TestFormsReachCompilerAndRuleMatcher(t *testing.T) {
	if os.Getenv("RULE_DNS_FORMS_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestFormsReachCompilerAndRuleMatcher$", "-test.v")
		cmd.Env = append(os.Environ(), "RULE_DNS_FORMS_CHILD=1")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("child: %v\n%s", err, output)
		}
		return
	}
	source := []byte(`proxies: [{name: node, type: direct}]
proxy-groups: [{name: manual, type: select, proxies: [node]}]
rules: ['DOMAIN-SUFFIX,public.test,DIRECT', 'DOMAIN,public.test,REJECT', 'MATCH,manual']
dns: {enable: true, nameserver: [https://resolver.test/dns-query], listen: '127.0.0.1:1053', x-advanced: {keep: true}}
x-top-level: {keep: true}
`)
	snapshot, err := configpipeline.ReadEditable(source, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	var rules []configpipeline.EditableItem
	var dns configpipeline.EditTarget
	for _, part := range snapshot.Sections {
		if part.Section == "rules" {
			rules = part.Items
		}
		if part.Section == "dns" {
			dns, err = configpipeline.ReadEditTarget(source, nil, nil, "dns", part.Items[0].ID)
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	input, _ := json.Marshal(map[string]any{"sourceRevision": snapshot.SourceRevision, "rule": rules[1], "before": rules[0].ID, "match": rules[2].ID, "dns": dns})
	cmd := exec.Command("node", "../../scripts/emit-rule-dns-fixture.cjs")
	cmd.Stdin = bytes.NewReader(input)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("form emission: %v %s", err, output)
	}
	intent, err := configpipeline.DecodeEditIntent(output)
	if err != nil {
		t.Fatal(err)
	}
	compiler := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(_ context.Context, data []byte) error { _, err := config.Parse(data); return err }}
	generated, err := compiler.Compile(context.Background(), configpipeline.Request{Original: source, Intent: intent})
	if err != nil {
		t.Fatal(err)
	}
	original, err := config.Parse(source)
	if err != nil {
		t.Fatal(err)
	}
	revised, err := config.Parse(generated.YAML)
	if err != nil {
		t.Fatal(err)
	}
	metadata := &C.Metadata{Host: "public.test"}
	first := func(rules []C.Rule) string {
		for _, rule := range rules {
			if matched, _ := rule.Match(metadata, C.RuleMatchHelper{}); matched {
				return rule.Adapter()
			}
		}
		return ""
	}
	if len(original.Rules) != len(revised.Rules) || first(original.Rules) != "DIRECT" || first(revised.Rules) != "REJECT" {
		t.Fatal("order did not change real matcher")
	}
	if revised.Rules[len(revised.Rules)-1].RuleType() != C.MATCH {
		t.Fatal("MATCH moved")
	}
	if !strings.Contains(string(generated.YAML), "keep: true") || !strings.Contains(string(generated.YAML), "127.0.0.1:1053") {
		t.Fatal("unknown/protected data lost")
	}
	if !bytes.Equal(generated.Original, source) {
		t.Fatal("original changed")
	}
	updated := append(append([]byte{}, source...), []byte("x-upstream: added\n")...)
	if _, err = compiler.Compile(context.Background(), configpipeline.Request{Original: updated, Intent: intent}); err != nil {
		t.Fatal("unrelated subscription update", err)
	}
	intent.Disabled = true
	undone, err := compiler.Compile(context.Background(), configpipeline.Request{Original: source, Intent: intent})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(undone.YAML), "dns.alidns.com") {
		t.Fatal("preset disable failed")
	}
}
