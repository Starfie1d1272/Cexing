package profiletemplates

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"core/configpipeline"
	"gopkg.in/yaml.v3"
)

func TestDeltaRegionRenameUnknownFieldAndNewMembers(t *testing.T) {
	ctx := context.Background()
	c := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: accept, PrepareTemplate: func(ctx context.Context, root *yaml.Node, p configpipeline.TemplatePlan) (*configpipeline.TemplateSession, error) {
		base, targets, err := Prepare(ctx, root, Plan{TemplateID: p.TemplateID, Version: p.Version, Region: p.Region})
		if err != nil {
			return nil, err
		}
		return &configpipeline.TemplateSession{Baseline: &base, Targets: targets, Capture: func(ctx context.Context, root *yaml.Node, targets map[string]*yaml.Node) (*configpipeline.TemplateSnapshot, error) {
			mine, err := CaptureEdited(ctx, root, base, targets)
			return &mine, err
		}}, nil
	}}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "private", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "region", Selector: "Pick", Enable: true}}}
	r := configpipeline.Request{Original: []byte(fixture), Intent: intent}
	target, err := c.EditTarget(ctx, r, "proxy-groups", TemplateTarget("region", "region/us"))
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{
		{ID: "personal-field", Kind: "update", Section: "proxy-groups", Target: target.Item.ID, Preconditions: map[string]string{"x-future": target.MissingFieldRevision}, Patch: json.RawMessage(`{"x-future":{"keep":[1,2]}}`)},
		{ID: "personal-rename", Kind: "rename", Section: "proxy-groups", Target: target.Item.ID, Expected: target.Item.Revision, Name: "My region"},
	}
	old, err := c.Compile(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	fresh := strings.Replace(fixture, "proxy-groups:", "  - {name: US-two, type: ss, server: 192.0.2.2, port: 443, cipher: aes-128-gcm, password: synthetic}\nproxy-groups:", 1)
	fresh = strings.Replace(fresh, "proxies: [US-one]", "proxies: [US-one, US-two]", 1)
	clean := *intent
	clean.Operations = []configpipeline.EditOperation{}
	clean.Template = old.EditIntent.Template
	next, err := c.Compile(ctx, configpipeline.Request{Original: []byte(fresh), Intent: &clean})
	if err != nil {
		t.Fatal(err)
	}
	preview, err := PreviewUpdate(ctx, UpdateRequest{Kind: "subscription", Base: *old.EditIntent.Template.Baseline, Mine: *old.EditIntent.Template.Mine, Next: *next.EditIntent.Template.Baseline})
	if err != nil || !preview.Ready {
		t.Fatal("independent membership/personal changes conflicted", err)
	}
	r.Original = []byte(fresh)
	r.Intent = old.EditIntent
	encoded, err := EncodeDelta(ctx, c, r, *old.EditIntent.Template.Baseline, *next.EditIntent.Template.Baseline, *preview.Candidate)
	if err != nil {
		t.Fatal(err)
	}
	result, err := c.Compile(ctx, configpipeline.Request{Original: []byte(fresh), Intent: encoded})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"US-two", "My region", "x-future:", "x-advanced:", "preserved"} {
		if !strings.Contains(string(result.YAML), want) {
			t.Fatal("field delta lost new/unknown content", want)
		}
	}
	a, _ := json.Marshal(result.EditIntent.Template.Mine)
	b, _ := json.Marshal(preview.Candidate)
	if string(a) != string(b) {
		t.Fatal("emitted mapping/rename did not reproduce candidate")
	}
}
