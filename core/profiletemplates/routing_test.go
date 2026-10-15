package profiletemplates

import (
	"context"
	"core/configpipeline"
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
