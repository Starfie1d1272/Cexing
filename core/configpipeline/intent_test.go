package configpipeline

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func editFixture(t *testing.T) []byte {
	t.Helper()
	b, e := os.ReadFile("testdata/edit-source.yaml")
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func editCompiler() Compiler {
	return Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(context.Context, []byte) error { return nil }}
}
func editTarget(t *testing.T, source []byte, section string, index int) EditTarget {
	t.Helper()
	s, e := ReadEditable(source, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	for _, part := range s.Sections {
		if part.Section == section {
			out, e := ReadEditTarget(source, nil, nil, section, part.Items[index].ID)
			if e != nil {
				t.Fatal(e)
			}
			return out
		}
	}
	t.Fatal("section missing")
	return EditTarget{}
}
func editPlan(t *testing.T, source []byte, ops ...EditOperation) *EditIntent {
	t.Helper()
	snapshot, e := ReadEditable(source, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	return &EditIntent{SchemaVersion: 1, Revision: "draft-1", SourceRevision: snapshot.SourceRevision, Operations: ops}
}
func TestIntentRebasePreservesSourceUnknownFieldsAndUndo(t *testing.T) {
	original := editFixture(t)
	target := editTarget(t, original, "proxies", 0)
	plan := editPlan(t, original, EditOperation{ID: "udp", Kind: "update", Section: "proxies", Target: target.Item.ID, Preconditions: map[string]string{"udp": target.Item.Fields["udp"]}, Patch: json.RawMessage(`{"udp":false}`)})
	updated := strings.Replace(string(original), "type: direct, udp: true", "type: direct, udp: true, tfo: true", 1) + "\nx-upstream: 42\n"
	c := editCompiler()
	r, e := c.Compile(context.Background(), Request{Original: []byte(updated), Intent: plan})
	if e != nil {
		t.Fatal(e)
	}
	if string(r.Original) != updated || !strings.Contains(string(r.YAML), "udp: false") || !strings.Contains(string(r.YAML), "tfo: true") || !strings.Contains(string(r.YAML), "future: preserved") || !strings.Contains(string(r.YAML), "x-upstream: 42") {
		t.Fatal("source or independent fields lost")
	}
	again, e := c.Compile(context.Background(), Request{Original: []byte(updated), Intent: plan})
	if e != nil || again.Digest != r.Digest {
		t.Fatal("recompile not idempotent", e)
	}
	plan.Disabled = true
	undo, e := c.Compile(context.Background(), Request{Original: []byte(updated), Intent: plan})
	if e != nil || !strings.Contains(string(undo.YAML), "udp: true") {
		t.Fatal("undo failed", e)
	}
	// Independent B subscription never receives A's plan unless explicitly supplied.
	b, e := c.Compile(context.Background(), Request{Original: original})
	if e != nil || !strings.Contains(string(b.YAML), "udp: true") {
		t.Fatal("B modified")
	}
}
func TestIntentConflictAndValidationHaveNoPublishedResult(t *testing.T) {
	source := editFixture(t)
	target := editTarget(t, source, "proxies", 0)
	op := EditOperation{ID: "udp", Kind: "update", Section: "proxies", Target: target.Item.ID, Preconditions: map[string]string{"udp": target.Item.Fields["udp"]}, Patch: json.RawMessage(`{"udp":false}`)}
	plan := editPlan(t, source, op)
	c := editCompiler()
	changed := strings.Replace(string(source), "udp: true", "udp: false", 1)
	r, e := c.Compile(context.Background(), Request{Original: []byte(changed), Intent: plan})
	var typed *IntentError
	if !errors.As(e, &typed) || typed.Code != "conflict" || typed.Operation != 0 || len(r.YAML) != 0 {
		t.Fatal("conflict not rejected", e)
	}
	c.Validate = func(context.Context, []byte) error { return errors.New("secret-private.test") }
	r, e = c.Compile(context.Background(), Request{Original: source, Intent: plan})
	if e == nil || strings.Contains(e.Error(), "private") || len(r.YAML) != 0 {
		t.Fatal("validation failure leaked/returned candidate")
	}
}
func TestIntentRenameMoveAddDeleteAndReferences(t *testing.T) {
	source := editFixture(t)
	group := editTarget(t, source, "proxy-groups", 0)
	rule := editTarget(t, source, "rules", 0)
	plan := editPlan(t, source,
		EditOperation{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: group.Item.ID, Expected: group.Item.Revision, Name: "renamed"},
		EditOperation{ID: "move", Kind: "move", Section: "rules", Target: rule.Item.ID},
		EditOperation{ID: "add", Kind: "add", Section: "proxies", Value: json.RawMessage(`{"name":"new","type":"direct"}`)},
	)
	// Rename changes rule identity: editing the old rule after rename must conflict,
	// rather than operate on another rule with the same position.
	if _, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan}); e == nil {
		t.Fatal("stale rule identity accepted")
	}
	plan.Operations = plan.Operations[:1]
	r, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil || !strings.Contains(string(r.YAML), "MATCH,renamed") {
		t.Fatal("rename references failed", e)
	}
	plan = editPlan(t, source, EditOperation{ID: "move", Kind: "move", Section: "rules", Target: rule.Item.ID}, EditOperation{ID: "add", Kind: "add", Section: "proxies", Value: json.RawMessage(`{"name":"new","type":"direct"}`)})
	r, e = editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil {
		t.Fatal(e)
	}
	root, _ := parse(r.YAML)
	if field(root, "rules").Content[0].Value != "MATCH,manual" || size(field(root, "proxies")) != 3 {
		t.Fatal("order/add lost")
	}
	node := editTarget(t, source, "proxies", 0)
	plan = editPlan(t, source, EditOperation{ID: "delete", Kind: "delete", Section: "proxies", Target: node.Item.ID, Expected: node.Item.Revision})
	if _, e = editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan}); e == nil {
		t.Fatal("dangling reference accepted")
	}
}
func TestIntentDNSTargetIsPatchAndPlatformProtected(t *testing.T) {
	source := editFixture(t)
	dns := editTarget(t, source, "dns", 0)
	op := EditOperation{ID: "dns", Kind: "update", Section: "dns", Target: dns.Item.ID, Preconditions: map[string]string{"nameserver": dns.Item.Fields["nameserver"]}, Patch: json.RawMessage(`{"nameserver":["1.1.1.1"]}`)}
	plan := editPlan(t, source, op)
	r, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil || !strings.Contains(string(r.YAML), "keep: true") {
		t.Fatal("DNS unknown fields lost", e)
	}
	plan.Operations[0].Patch = json.RawMessage(`{"listen":"0.0.0.0:53"}`)
	plan.Operations[0].Preconditions = map[string]string{"listen": MissingFieldRevision()}
	if _, e = editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan}); e == nil {
		t.Fatal("DNS listen accepted")
	}
	plan.Operations[0].Section = "tun"
	if e = CheckEditIntent(plan); e == nil {
		t.Fatal("protected section accepted")
	}
}
func TestIntentPrivacySchemaDuplicatesAndDoubleMerge(t *testing.T) {
	source := editFixture(t)
	s, e := ReadEditable(source, []byte("dns: {enable: false}\n"), []byte("dns: {enable: true}\n"))
	if e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(s)
	for _, private := range []string{"node-a", "private.test", "resolver.test", "public.test", "preserved"} {
		if strings.Contains(string(b), private) {
			t.Fatal("summary leak", private)
		}
	}
	source2 := strings.Replace(string(source), "  - MATCH,manual", "  - DOMAIN,public.test,manual\n  - MATCH,manual", 1)
	first := editTarget(t, source, "rules", 0)
	plan := editPlan(t, source, EditOperation{ID: "delete", Kind: "delete", Section: "rules", Target: first.Item.ID, Expected: first.Item.Revision})
	// A delete tombstone for a now ambiguous duplicate identity must not delete either.
	r, e := editCompiler().Compile(context.Background(), Request{Original: []byte(source2), Intent: plan})
	if e == nil || len(r.YAML) != 0 {
		t.Fatal("ambiguous duplicate accepted")
	}
	for _, bad := range []string{`{"schemaVersion":2}`, `{"schemaVersion":1,"revision":"d","sourceRevision":"s","operations":[],"unknown":true}`, `{"schemaVersion":1,"revision":"d","sourceRevision":"s","operations":[]} trailing`} {
		if _, e := DecodeEditIntent([]byte(bad)); e == nil {
			t.Fatal("invalid schema accepted")
		}
	}
	dns, e := ReadEditTarget(source, []byte("dns: {enable: false}\n"), []byte("dns: {enable: true}\n"), "dns", s.Sections[5].Items[0].ID)
	if e != nil || !strings.Contains(string(dns.Value), `"enable":true`) {
		t.Fatal("layered merge mismatch", e)
	}
}

func TestIntentPublicFixtureAndMissingDNS(t *testing.T) {
	source := editFixture(t)
	data, e := os.ReadFile("testdata/edit-intent.json")
	if e != nil {
		t.Fatal(e)
	}
	plan, e := DecodeEditIntent(data)
	if e != nil {
		t.Fatal(e)
	}
	snapshot, e := ReadEditable(source, nil, nil)
	if e != nil || snapshot.SourceRevision != plan.SourceRevision {
		t.Fatal("fixture drift", e)
	}
	r, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil || !strings.Contains(string(r.YAML), "udp: false") {
		t.Fatal("fixture failed", e)
	}
	minimal := []byte("proxies: [{name: a, type: direct}]\nrules: [\"MATCH,DIRECT\"]\n")
	dns := editTarget(t, minimal, "dns", 0)
	plan = editPlan(t, minimal, EditOperation{ID: "enable", Kind: "update", Section: "dns", Target: dns.Item.ID, Preconditions: map[string]string{"enable": MissingFieldRevision()}, Patch: json.RawMessage(`{"enable":true}`)})
	r, e = editCompiler().Compile(context.Background(), Request{Original: minimal, Intent: plan})
	if e != nil || !strings.Contains(string(r.YAML), "enable: true") {
		t.Fatal("missing DNS not created", e)
	}
	if MissingFieldRevision() == fingerprint(&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!null", Value: "null"}) {
		t.Fatal("missing and null conflated")
	}
}

func TestTemplateBeforePersonalEditsAndResultIntentSnapshot(t *testing.T) {
	source := editFixture(t)
	// Read the template-generated view as the personal-edit authoring baseline.
	templateSource := strings.Replace(string(source), "  - MATCH,manual", "  - DOMAIN-SUFFIX,template.test,manual\n  - MATCH,manual", 1)
	first := editTarget(t, []byte(templateSource), "rules", 1)
	plan := editPlan(t, []byte(templateSource), EditOperation{ID: "personal-delete", Kind: "delete", Section: "rules", Target: first.Item.ID, Expected: first.Item.Revision})
	plan.Template = &TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "manual"}
	c := editCompiler()
	c.Template = func(_ context.Context, root *yaml.Node, p TemplatePlan) error {
		if p.TemplateID != "ai" {
			t.Fatal("wrong template")
		}
		rules := field(root, "rules")
		rules.Content = append(rules.Content[:1], append([]*yaml.Node{scalar("DOMAIN-SUFFIX,template.test,manual")}, rules.Content[1:]...)...)
		return nil
	}
	r, e := c.Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(string(r.YAML), "template.test") || r.EditIntent == nil {
		t.Fatal("template overwrote personal intent")
	}
	plan.Template.TargetGroup = "changed"
	plan.Operations[0].Expected = "changed"
	if r.EditIntent.Template.TargetGroup != "manual" || r.EditIntent.Operations[0].Expected == "changed" {
		t.Fatal("result shares mutable draft")
	}
	c.Template = nil
	plan = r.EditIntent
	r, e = c.Compile(context.Background(), Request{Original: source, Intent: plan})
	var failure *IntentError
	if !errors.As(e, &failure) || failure.Code != "template_unavailable" || len(r.YAML) != 0 {
		t.Fatal("missing adapter silently skipped", e)
	}
}

func TestIntentRenameExactRuleTargetKeepsPayloadAndParams(t *testing.T) {
	for _, old := range []string{"no", "no-resolve"} {
		t.Run(old, func(t *testing.T) {
			source := []byte("proxies: [{name: a, type: direct}]\nproxy-groups: [{name: " + old + ", type: select, proxies: [a]}]\nrules:\n" +
				" - 'DOMAIN,no," + old + "'\n" +
				" - 'IP-CIDR,192.0.2.0/24," + old + ",no-resolve'\n" +
				" - 'IP-CIDR,192.0.2.0/24, " + old + " ,no-resolve,src'\n" +
				" - 'AND,((DOMAIN,no),(IP-CIDR,192.0.2.0/24))," + old + "'\n" +
				" - 'DOMAIN-REGEX,^no,no-resolve$," + old + "'\n" +
				" - 'MATCH," + old + "'\n")
			target := editTarget(t, source, "proxy-groups", 0)
			plan := editPlan(t, source, EditOperation{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: target.Item.ID, Expected: target.Item.Revision, Name: "renamed"})
			r, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
			if e != nil {
				t.Fatal(e)
			}
			root, _ := parse(r.YAML)
			rules := field(root, "rules").Content
			expected := []string{"DOMAIN,no,renamed", "IP-CIDR,192.0.2.0/24,renamed,no-resolve", "IP-CIDR,192.0.2.0/24, renamed ,no-resolve,src", "AND,((DOMAIN,no),(IP-CIDR,192.0.2.0/24)),renamed", "DOMAIN-REGEX,^no,no-resolve$,renamed", "MATCH,renamed"}
			for i, rule := range rules {
				if rule.Value != expected[i] {
					t.Fatalf("rule %d changed payload/params: %q", i, rule.Value)
				}
			}
		})
	}
	if got := replaceRuleToken("RULE-SET, no ,group,no-resolve", 1, "no", "renamed"); got != "RULE-SET, renamed ,group,no-resolve" {
		t.Fatal("provider token lost spaces", got)
	}
}

func TestEditorProjectionShowsDraftWithoutValidateOrPublication(t *testing.T) {
	source := editFixture(t)
	target := editTarget(t, source, "proxies", 0)
	plan := editPlan(t, source, EditOperation{ID: "udp", Kind: "update", Section: "proxies", Target: target.Item.ID, Preconditions: map[string]string{"udp": target.Item.Fields["udp"]}, Patch: json.RawMessage(`{"udp":false}`)})
	c := Compiler{Validate: func(context.Context, []byte) error { t.Fatal("read invoked full parser"); return nil }}
	view, e := c.Editable(context.Background(), Request{Original: source, Intent: plan})
	if e != nil {
		t.Fatal(e)
	}
	if view.Sections[0].Items[0].ID != target.Item.ID {
		t.Fatal("unrelated field changed stable ID")
	}
	edited, e := c.EditTarget(context.Background(), Request{Original: source, Intent: plan}, "proxies", target.Item.ID)
	if e != nil || !strings.Contains(string(edited.Value), `"udp":false`) {
		t.Fatal("draft view still shows original", e)
	}
	if strings.Contains(string(source), "udp: false") {
		t.Fatal("source mutated")
	}
}

func TestIntentDNSPolicyOrderParticipatesInSourceAndFieldRevision(t *testing.T) {
	source := []byte("proxies: [{name: a, type: direct}]\ndns: {nameserver-policy: {private-a.test: 1.1.1.1, private-b.test: 8.8.8.8}}\n")
	changed := []byte("proxies: [{name: a, type: direct}]\ndns: {nameserver-policy: {private-b.test: 8.8.8.8, private-a.test: 1.1.1.1}}\n")
	a, e := ReadEditable(source, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	b, e := ReadEditable(changed, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	if a.SourceRevision == b.SourceRevision {
		t.Fatal("ordered DNS policy source change not revisioned")
	}
	dns := editTarget(t, source, "dns", 0)
	plan := editPlan(t, source, EditOperation{ID: "dns-policy", Kind: "update", Section: "dns", Target: dns.Item.ID, Preconditions: map[string]string{"nameserver-policy": dns.Item.Fields["nameserver-policy"]}, Patch: json.RawMessage(`{"nameserver-policy":{"private-c.test":"9.9.9.9"}}`)})
	if _, e = editCompiler().Compile(context.Background(), Request{Original: changed, Intent: plan}); e == nil {
		t.Fatal("upstream priority change silently overwritten")
	}
}

func TestIntentCompoundUpdateRenameUsesOriginalGuardAndRejectsRealSourceChange(t *testing.T) {
	source := editFixture(t)
	target := editTarget(t, source, "proxies", 0)
	plan := editPlan(t, source,
		EditOperation{ID: "update", Kind: "update", Section: "proxies", Target: target.Item.ID, Preconditions: map[string]string{"udp": target.Item.Fields["udp"]}, Patch: json.RawMessage(`{"udp":false}`)},
		EditOperation{ID: "rename", Kind: "rename", Section: "proxies", Target: target.Item.ID, Expected: target.Item.Revision, Name: "renamed-node"},
	)
	before, _ := json.Marshal(plan)
	r, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil {
		t.Fatal("own update invalidates original rename guard", e)
	}
	if !strings.Contains(string(r.YAML), "name: renamed-node") || !strings.Contains(string(r.YAML), "udp: false") {
		t.Fatal("compound edit lost fields")
	}
	again, e := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if e != nil || again.Digest != r.Digest {
		t.Fatal("compound recompile not idempotent", e)
	}
	after, _ := json.Marshal(plan)
	if string(before) != string(after) {
		t.Fatal("compile rewrote authored guards")
	}
	changed := []byte(strings.Replace(string(source), "udp: true", "udp: false", 1))
	if _, e = editCompiler().Compile(context.Background(), Request{Original: changed, Intent: plan}); e == nil {
		t.Fatal("real upstream conflict bypassed")
	}
}

func TestIntentCrossObjectRenameUsesOriginalBaseline(t *testing.T) {
	source := []byte("proxies: [{name: node, type: direct}]\nproxy-groups: [{name: group, type: select, proxies: [node]}]\nrules: ['MATCH,group']\n")
	node := editTarget(t, source, "proxies", 0)
	group := editTarget(t, source, "proxy-groups", 0)
	plan := editPlan(t, source, EditOperation{ID: "node", Kind: "rename", Section: "proxies", Target: node.Item.ID, Expected: node.Item.Revision, Name: "new-node"}, EditOperation{ID: "group", Kind: "rename", Section: "proxy-groups", Target: group.Item.ID, Expected: group.Item.Revision, Name: "new-group"})
	result, err := editCompiler().Compile(context.Background(), Request{Original: source, Intent: plan})
	if err != nil || !strings.Contains(string(result.YAML), "MATCH,new-group") {
		t.Fatal("unchanged chained references rejected", err)
	}
	changed := []byte(strings.Replace(string(source), "proxies: [node]", "proxies: [DIRECT]", 1))
	if _, err = editCompiler().Compile(context.Background(), Request{Original: changed, Intent: plan}); err == nil {
		t.Fatal("real upstream change admitted")
	}
}

func TestRuleSummaryTypesUseParserWhitelistWithoutPayload(t *testing.T) {
	source := []byte("rules: ['DOMAIN,private.synthetic,DIRECT', 'AND,((DOMAIN,private.synthetic),(NETWORK,TCP)),DIRECT', 'MATCH,DIRECT', 'PRIVATE-TYPE,private.synthetic,DIRECT']\n")
	c := Compiler{}
	ctx := context.Background()
	r := Request{Original: source}
	for _, read := range []func(context.Context, Request) (EditableSnapshot, error){c.Editable, c.EditorList} {
		view, err := read(ctx, r)
		if err != nil {
			t.Fatal(err)
		}
		rules := view.Sections[3].Items
		want := []string{"DOMAIN", "AND", "MATCH", ""}
		for i, item := range rules {
			if item.Type != want[i] {
				t.Fatal("rule metadata missing or unsafe", i, item.Type)
			}
		}
		encoded, _ := json.Marshal(view)
		if strings.Contains(string(encoded), "private.synthetic") || strings.Contains(string(encoded), "PRIVATE-TYPE") {
			t.Fatal("private rule payload leaked in summary")
		}
		explicit, err := c.EditTarget(ctx, r, "rules", rules[2].ID)
		if err != nil || explicit.Item.Type != "MATCH" {
			t.Fatal("explicit target metadata diverged", err)
		}
	}
}
