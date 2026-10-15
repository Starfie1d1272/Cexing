package profiletemplates

import (
	"context"
	"core/configpipeline"
	"encoding/json"
	"gopkg.in/yaml.v3"
	"strings"
	"testing"
)

func TestRoutingBindingsAndLegacyArchive(t *testing.T) {
	root, err := configpipeline.LayeredMergeSource([]byte("proxies: [{name: JP fixture, type: socks5, server: node.example.test, port: 1080}]\nproxy-groups: [{name: Original, type: select, proxies: [JP fixture]}]\nrules: [MATCH,Original]\n"), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	digest, _ := configpipeline.RoutingOverlayDigest(nil)
	routing := &configpipeline.RoutingPlan{Version: 1, Mode: "managed", OverlayRulesDigest: digest, DefaultOutlet: "default", Outlets: []configpipeline.RoutingOutlet{{ID: "default", Algorithm: "smart", Scope: configpipeline.RoutingScope{Unknown: "include"}}}, Routes: []configpipeline.RoutingRoute{{ID: "ai", Services: []string{"category-ai-!cn"}, Outlet: "default"}}}
	plan := Plan{TemplateID: "routing", Version: 1, Routing: routing}
	base, targets, err := Prepare(context.Background(), root, plan)
	if err != nil {
		t.Fatal(err)
	}
	// 5602 domestic expressions stay in bounded inline providers, never thousands
	// of generated operations or an online rule URL.
	if len(base.Entries) > 64 {
		t.Fatalf("unexpected binding count %d", len(base.Entries))
	}
	if _, err := CaptureEdited(context.Background(), root, base, targets); err != nil {
		t.Fatal(err)
	}
	old := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "Original"}}
	next := configpipeline.TemplatePlan{TemplateID: "routing", Version: 1, Routing: routing}
	switched, err := configpipeline.SwitchTemplate(old, next, false)
	if err != nil {
		t.Fatal(err)
	}
	if switched.Intent.TemplateArchives["ai"].TargetGroup != "Original" {
		t.Fatal("legacy semantics lost")
	}
	back, err := configpipeline.SwitchTemplate(switched.Intent, *old.Template, false)
	if err != nil || back.Intent.Template.TargetGroup != "Original" {
		t.Fatal("legacy restore failed", err)
	}
}

func TestRoutingPurposeNamesRetainBindingsPersonalRenameAndSmartChoice(t *testing.T) {
	original := []byte("proxies: [{name: US fixture, type: socks5, server: node.example.test, port: 1080}]\nproxy-groups: [{name: Original, type: select, proxies: [US fixture]}]\nrules: ['MATCH,Original']\n")
	digest, _ := configpipeline.RoutingOverlayDigest(nil)
	routing := &configpipeline.RoutingPlan{Version: 1, Mode: "managed", DefaultOutlet: "default", OverlayRulesDigest: digest,
		Outlets: []configpipeline.RoutingOutlet{{ID: "default", Algorithm: "smart", Scope: configpipeline.RoutingScope{Unknown: "include"}}, {ID: "exit-1", Algorithm: "url-test", Scope: configpipeline.RoutingScope{Unknown: "exclude", Regions: []string{"美国"}}}},
		Routes:  []configpipeline.RoutingRoute{{ID: "service", Services: []string{"openai"}, Outlet: "exit-1"}}}
	compiler := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(context.Context, []byte) error { return nil }, PrepareTemplate: func(ctx context.Context, root *yaml.Node, p configpipeline.TemplatePlan) (*configpipeline.TemplateSession, error) {
		base, targets, err := Prepare(ctx, root, Plan{TemplateID: p.TemplateID, Version: p.Version, Routing: p.Routing})
		if err != nil {
			return nil, err
		}
		return &configpipeline.TemplateSession{Baseline: &base, Targets: targets, Capture: func(ctx context.Context, root *yaml.Node, targets map[string]*yaml.Node) (*configpipeline.TemplateSnapshot, error) {
			mine, e := CaptureEdited(ctx, root, base, targets)
			return &mine, e
		}}, nil
	}}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "routing", Version: 1, Routing: routing}}
	first, err := compiler.Compile(context.Background(), configpipeline.Request{Original: original, Intent: intent})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(first.YAML), "Cexing / default") || strings.Contains(string(first.YAML), "exit-1") || !strings.Contains(string(first.YAML), "ChatGPT / OpenAI") {
		t.Fatal("internal identifiers reached panel labels")
	}
	intent = first.EditIntent
	alias := configpipeline.TemplateTarget("routing", configpipeline.RoutingOutletTargetID("exit-1"))
	target, err := compiler.EditTarget(context.Background(), configpipeline.Request{Original: original, Intent: intent}, "proxy-groups", alias)
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: alias, Expected: target.Item.Revision, Name: "Personal exit"}}
	intent.Template.Routing.Routes[0].Services = []string{"anthropic"}
	var preview []configpipeline.SmartGroupChange
	result, err := compiler.Compile(context.Background(), configpipeline.Request{Original: original, Intent: intent, Strategy: func(ctx context.Context, root *yaml.Node) error {
		var e error
		preview, e = configpipeline.PreviewSmartPolicy(root, true, intent)
		if e != nil {
			return e
		}
		return configpipeline.ApplySmartPolicy(ctx, root, true, intent)
	}})
	if err != nil {
		t.Fatal("display-name rebase broke personal rename", err)
	}
	if len(preview) != 0 || !strings.Contains(string(result.YAML), "Personal exit") || !strings.Contains(string(result.YAML), "type: url-test") {
		t.Fatal("personal name or explicit algorithm was lost")
	}
	raw, _ := json.Marshal(intent)
	var copied configpipeline.EditIntent
	_ = json.Unmarshal(raw, &copied)
	copied.Template.Routing.Outlets[1].Algorithm = "fallback"
	copied.Template.Routing.Outlets[1].Order = []string{"US fixture"}
	if _, err := compiler.Compile(context.Background(), configpipeline.Request{Original: original, Intent: &copied}); err == nil {
		t.Fatal("unrelated algorithm change bypassed revision guard")
	}
}
