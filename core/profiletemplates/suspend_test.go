package profiletemplates

import (
	"context"
	"core/configpipeline"
	"encoding/json"
	"gopkg.in/yaml.v3"
	"strings"
	"testing"
)

func TestTemplateStopKeepsIndependentEditsAndRestoresOwnedChanges(t *testing.T) {
	ctx := context.Background()
	c := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: accept, PrepareTemplate: func(ctx context.Context, root *yaml.Node, p configpipeline.TemplatePlan) (*configpipeline.TemplateSession, error) {
		base, targets, err := Prepare(ctx, root, Plan{TemplateID: p.TemplateID, Version: p.Version, Region: p.Region, TargetGroup: p.TargetGroup, ReplaceRules: p.ReplaceRules})
		if err != nil {
			return nil, err
		}
		return &configpipeline.TemplateSession{Baseline: &base, Targets: targets, Capture: func(ctx context.Context, root *yaml.Node, targets map[string]*yaml.Node) (*configpipeline.TemplateSnapshot, error) {
			mine, e := CaptureEdited(ctx, root, base, targets)
			return &mine, e
		}}, nil
	}}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "region", Selector: "Pick", Enable: true, Assignments: map[string]string{"US-one": "美国"}}}}
	request := configpipeline.Request{Original: []byte(fixture), Intent: intent}
	target, err := c.EditTarget(ctx, request, "proxy-groups", TemplateTarget("region", "region/us"))
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{
		{ID: "rename-region", Kind: "rename", Section: "proxy-groups", Target: target.Item.ID, Expected: target.Item.Revision, Name: "My region"},
		{ID: "personal-node", Kind: "add", Section: "proxies", Value: json.RawMessage(`{"name":"Personal","type":"direct"}`)},
		{ID: "dependent-rule", Kind: "add", Section: "rules", Value: json.RawMessage(`"DOMAIN,dependent.synthetic,My region"`)},
	}
	original, err := c.Compile(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	inputBytes, _ := json.Marshal(original.EditIntent)
	paused, err := configpipeline.SwitchTemplate(original.EditIntent, configpipeline.TemplatePlan{TemplateID: "original", Version: 1}, false)
	if err != nil || paused.DependentCount != 1 || paused.Intent != nil {
		t.Fatalf("missing explicit dependency choice: %+v %v", paused, err)
	}
	afterBytes, _ := json.Marshal(original.EditIntent)
	if string(inputBytes) != string(afterBytes) {
		t.Fatal("preview mutated source intent")
	}
	paused, err = configpipeline.SwitchTemplate(original.EditIntent, configpipeline.TemplatePlan{TemplateID: "original", Version: 1}, true)
	if err != nil {
		t.Fatal(err)
	}
	stopped, err := c.Compile(ctx, configpipeline.Request{Original: []byte(fixture), Intent: paused.Intent})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(stopped.YAML), "Personal") || strings.Contains(string(stopped.YAML), "My region") || strings.Contains(string(stopped.YAML), "dependent.synthetic") {
		t.Fatalf("stop lost unrelated edit or left template reference: %s / %+v", stopped.YAML, paused.Intent)
	}
	if len(stopped.EditIntent.Operations) != 3 || len(stopped.EditIntent.TemplateArchives) != 1 {
		t.Fatal("paused edits were deleted")
	}
	resumed, err := configpipeline.SwitchTemplate(stopped.EditIntent, *intent.Template, false)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := c.Compile(ctx, configpipeline.Request{Original: []byte(fixture), Intent: resumed.Intent})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(restored.YAML), "My region") || !strings.Contains(string(restored.YAML), "dependent.synthetic") || !strings.Contains(string(restored.YAML), "Personal") {
		t.Fatal("reactivation failed to restore edits")
	}
}
