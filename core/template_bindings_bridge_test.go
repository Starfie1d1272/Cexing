package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"core/configpipeline"
	"core/profiletemplates"
	"github.com/metacubex/mihomo/adapter"
	"gopkg.in/yaml.v3"
)

func TestTemplateAliasReplacementDeletionAndSuccessfulProvenance(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	source := []byte("proxies: [{name: node, type: direct}]\nproxy-groups: [{name: AI, type: select, proxies: [node]}]\nrules: ['MATCH,AI']\nx-unknown: {future: preserved}\n")
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "AI"}}
	c := configpipeline.Compiler{PrepareTemplate: editorTemplatePrepare(home), Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(context.Context, []byte) error { return nil }}
	first := profiletemplates.TemplateTarget("ai", "ai/chatgpt")
	second := profiletemplates.TemplateTarget("ai", "ai/openai")
	r := configpipeline.Request{Original: source, Intent: intent}
	target, err := c.EditTarget(ctx, r, "rules", first)
	if err != nil {
		t.Fatal(err)
	}
	if target.Item.ID != first {
		t.Fatal("read did not expose stable alias")
	}
	next, err := c.EditTarget(ctx, r, "rules", second)
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{{ID: "replace", Kind: "update", Section: "rules", Target: first, Expected: target.Item.Revision, Value: json.RawMessage(`"DOMAIN,personal.synthetic,AI"`)}, {ID: "move", Kind: "move", Section: "rules", Target: first, Before: profiletemplates.TemplateTarget("ai", "ai/anthropic")}, {ID: "delete", Kind: "delete", Section: "rules", Target: second, Expected: next.Item.Revision}}
	before, _ := json.Marshal(intent)
	result, err := c.Compile(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	after, _ := json.Marshal(intent)
	if string(before) != string(after) {
		t.Fatal("preview mutated input intent")
	}
	if !strings.Contains(string(result.YAML), "personal.synthetic") || strings.Contains(string(result.YAML), "DOMAIN-SUFFIX,openai.com,") || !strings.Contains(string(result.YAML), "future: preserved") {
		t.Fatal("template edits lost")
	}
	p := result.EditIntent.Template
	if p.Baseline == nil || p.Mine == nil || len(p.Baseline.Entries) != 8 || len(p.Mine.Entries) != 7 || len(p.Mine.Deleted) != 1 || p.Mine.Deleted[0] != "ai/openai" {
		t.Fatal("successful private provenance missing", p)
	}
	if p.Mine.Entries[0].ID == "ai/chatgpt" {
		t.Fatal("Mine lost actual edited order")
	}
	if !strings.Contains(string(p.Mine.Entries[3].Value), "personal.synthetic") {
		t.Fatal("replacement captured stale node")
	}
	encoded, _ := json.Marshal(result.EditIntent)
	restored, err := configpipeline.DecodeEditIntent(encoded)
	if err != nil {
		t.Fatal(err)
	}
	again, err := c.Compile(ctx, configpipeline.Request{Original: source, Intent: restored})
	if err != nil || again.Digest != result.Digest {
		t.Fatal("restart changed result", err)
	}
	read, err := c.EditTarget(ctx, r, "rules", first)
	if err != nil || read.Item.ID != first || !strings.Contains(string(read.Value), "personal.synthetic") {
		t.Fatal("replacement changed logical identity", err)
	}
	if _, err = c.EditTarget(ctx, r, "rules", second); err == nil {
		t.Fatal("deleted alias still readable")
	}
	list, err := c.EditorList(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, s := range list.Sections {
		for _, i := range s.Items {
			if i.ID == first {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("list lost alias")
	}
	c.Validate = func(context.Context, []byte) error { return context.Canceled }
	failed, err := c.Compile(ctx, r)
	if err == nil || failed.EditIntent != nil {
		t.Fatal("failed validation returned successful provenance")
	}
}
func TestTemplateUpdateRoutesThroughExistingWorkerDispatcher(t *testing.T) {
	input := `{"op":"template-update-preview","request":{"kind":"subscription","base":{"templateId":"ai","version":1,"entries":[]},"mine":{"templateId":"ai","version":1,"entries":[]},"next":{"templateId":"ai","version":1,"entries":[]}}}`
	if output := coreVersionAction(t.TempDir(), input); !strings.Contains(output, `"ready":true`) {
		t.Fatal("dispatcher did not route", output)
	}
	if output := coreVersionAction(t.TempDir(), strings.Replace(input, `"kind":`, `"unknown":1,"kind":`, 1)); !strings.Contains(output, "TEMPLATE_UPDATE_INVALID") {
		t.Fatal("dispatcher bypassed bounded decoder", output)
	}
}

func TestRetainedRemovedRegionAliasSurvivesReappearance(t *testing.T) {
	ctx := context.Background()
	c := configpipeline.Compiler{PrepareTemplate: editorTemplatePrepare(t.TempDir()), Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(context.Context, []byte) error { return nil }}
	source := "proxies: [{name: US-one, type: direct}, {name: HK-one, type: direct}]\nproxy-groups: [{name: Pick, type: select, proxies: [US-one]}]\nrules: ['MATCH,Pick']\n"
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "region", Selector: "Pick", Enable: true}}}
	target, err := c.EditTarget(ctx, configpipeline.Request{Original: []byte(source), Intent: intent}, "proxy-groups", profiletemplates.TemplateTarget("region", "region/us"))
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{{ID: "personal", Kind: "update", Section: "proxy-groups", Target: target.Item.ID, Preconditions: map[string]string{"x-personal": target.MissingFieldRevision}, Patch: json.RawMessage(`{"x-personal":true}`)}}
	current, err := c.Compile(ctx, configpipeline.Request{Original: []byte(source), Intent: intent})
	if err != nil {
		t.Fatal(err)
	}
	for _, updated := range []string{strings.Replace(source, "proxies: [US-one]", "proxies: [HK-one]", 1), source} {
		clean := *current.EditIntent
		clean.Operations = []configpipeline.EditOperation{}
		fresh, err := c.Compile(ctx, configpipeline.Request{Original: []byte(updated), Intent: &clean})
		if err != nil {
			t.Fatal(err)
		}
		req := profiletemplates.UpdateRequest{Kind: "subscription", Base: *current.EditIntent.Template.Baseline, Mine: *current.EditIntent.Template.Mine, Next: *fresh.EditIntent.Template.Baseline}
		preview, err := profiletemplates.PreviewUpdate(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		req.Decisions = map[string]string{}
		for _, conflict := range preview.Conflicts {
			req.Decisions[conflict.ID] = "mine"
		}
		preview, err = profiletemplates.PreviewUpdate(ctx, req)
		if err != nil || !preview.Ready {
			t.Fatal("retention conflict resolution failed", err)
		}
		nextIntent, err := profiletemplates.EncodeDelta(ctx, c, configpipeline.Request{Original: []byte(updated), Intent: current.EditIntent}, req.Base, req.Next, *preview.Candidate)
		if err != nil {
			t.Fatal(err)
		}
		current, err = c.Compile(ctx, configpipeline.Request{Original: []byte(updated), Intent: nextIntent})
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, e := range current.EditIntent.Template.Mine.Entries {
			if e.ID == "region/us" && strings.Contains(string(e.Value), "x-personal") {
				found = true
			}
		}
		if !found {
			t.Fatal("retained logical entity lost from successful Mine")
		}
		view, err := c.EditTarget(ctx, configpipeline.Request{Original: []byte(updated), Intent: current.EditIntent}, "proxy-groups", profiletemplates.TemplateTarget("region", "region/us"))
		if err != nil || !strings.Contains(string(view.Value), "x-personal") {
			t.Fatal("retained alias lost across recompile", err)
		}
	}
}
func TestTemplateTargetSourceNameFollowsPersonalRename(t *testing.T) {
	source := []byte("proxies: [{name: node, type: direct}]\nproxy-groups: [{name: Old, type: select, proxies: [node]}]\nrules: ['MATCH,Old']\n")
	c := configpipeline.Compiler{}
	ctx := context.Background()
	r := configpipeline.Request{Original: source}
	list, err := c.EditorList(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	var target configpipeline.EditableItem
	for _, s := range list.Sections {
		if s.Section == "proxy-groups" {
			target = s.Items[0]
		}
	}
	r.Intent = &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: target.ID, Expected: target.Revision, Name: "New"}, {ID: "added", Kind: "add", Section: "proxy-groups", Value: json.RawMessage(`{"name":"Personal","type":"select","proxies":["DIRECT"]}`)}}}
	list, err = c.EditorList(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range list.Sections {
		if s.Section == "proxy-groups" {
			for _, item := range s.Items {
				if item.Name == "New" && item.SourceName != "Old" {
					t.Fatal("rename lost pre-template value")
				}
				if item.Name == "Personal" && item.SourceName != "" {
					t.Fatal("personal group advertised as pre-template target")
				}
			}
		}
	}
}

func TestDisabledProxyUsesLockedRejectAdapter(t *testing.T) {
	source := []byte("proxies: [{name: Disabled, type: direct}]\nproxy-groups: [{name: Pick, type: select, proxies: [Disabled]}]\nrules: ['MATCH,Disabled']\n")
	ctx := context.Background()
	c := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil }, Validate: func(_ context.Context, data []byte) error {
		var document struct {
			Proxies []map[string]any `yaml:"proxies"`
		}
		if err := yaml.Unmarshal(data, &document); err != nil {
			return err
		}
		_, err := adapter.ParseProxy(document.Proxies[0])
		return err
	}}
	list, err := c.EditorList(ctx, configpipeline.Request{Original: source})
	if err != nil {
		t.Fatal(err)
	}
	item := list.Sections[0].Items[0]
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{{ID: "off", Kind: "disable", Section: "proxies", Target: item.ID, Expected: item.Revision}}}
	if _, err = c.Compile(ctx, configpipeline.Request{Original: source, Intent: intent}); err != nil {
		t.Fatal("locked parser rejected fail-closed placeholder", err)
	}
}
