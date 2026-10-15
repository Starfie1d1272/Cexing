package configpipeline

import (
	"encoding/json"
	"testing"
)

func TestTemplateSwitchTracksDependentEntityRenameChain(t *testing.T) {
	base := &TemplateSnapshot{TemplateID: "region", Version: 1, Entries: []TemplateEntity{{ID: "region/us", Section: "proxy-groups", Value: json.RawMessage(`{"name":"G","type":"select","proxies":["DIRECT"]}`)}}}
	intent := &EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Template: &TemplatePlan{TemplateID: "region", Version: 1, Region: &RegionPlan{Mode: "region", Selector: "Pick", Enable: true}, Baseline: base, Mine: base}, Operations: []EditOperation{
		{ID: "add", Kind: "add", Section: "proxy-groups", Value: json.RawMessage(`{"name":"P","type":"select","proxies":["G"]}`)},
		{ID: "edit", Kind: "update", Section: "proxy-groups", Target: targetID("proxy-groups", "P"), Patch: json.RawMessage(`{"hidden":true}`), Preconditions: map[string]string{"hidden": MissingFieldRevision()}},
		{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: targetID("proxy-groups", "P"), Name: "Q", Expected: "revision"},
		{ID: "rule", Kind: "add", Section: "rules", Value: json.RawMessage(`"DOMAIN,example.synthetic,Q"`)},
		{ID: "personal", Kind: "add", Section: "proxies", Value: json.RawMessage(`{"name":"Personal","type":"direct"}`)},
	}}
	r, err := SwitchTemplate(intent, TemplatePlan{TemplateID: "original", Version: 1}, false)
	if err != nil || r.DependentCount != 4 || r.Intent != nil {
		t.Fatalf("dependency closure: %+v %v", r, err)
	}
	r, err = SwitchTemplate(intent, TemplatePlan{TemplateID: "original", Version: 1}, true)
	if err != nil {
		t.Fatal(err)
	}
	for i, op := range r.Intent.Operations {
		if (i < 4) != (op.TemplateID == "region") {
			t.Fatalf("wrong ownership: %+v", op)
		}
	}
	if intent.Operations[0].TemplateID != "" {
		t.Fatal("input mutated")
	}
}

func TestTemplateSwitchConsumesArchiveAndHonorsSameTemplateAssignments(t *testing.T) {
	current := TemplatePlan{TemplateID: "region", Version: 1, Region: &RegionPlan{Mode: "region", Selector: "Pick", Enable: true, Assignments: map[string]string{"node": "美国"}}}
	intent := &EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Template: &current, Operations: []EditOperation{}}
	next := current
	region := *current.Region
	region.Assignments = map[string]string{"node": "日本"}
	next.Region = &region
	r, err := SwitchTemplate(intent, next, false)
	if err != nil || r.Intent.Template.Region.Assignments["node"] != "日本" {
		t.Fatalf("new assignment overwritten: %+v %v", r, err)
	}
	stopped, err := SwitchTemplate(r.Intent, TemplatePlan{TemplateID: "original", Version: 1}, true)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := SwitchTemplate(stopped.Intent, current, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.Intent.TemplateArchives) != 0 || restored.Intent.Template.Region.Assignments["node"] != "日本" {
		t.Fatal("archive not consumed/restored")
	}
}

func TestTemplateSwitchKeepsIndependentFieldsOnExistingGroup(t *testing.T) {
	base := &TemplateSnapshot{TemplateID: "region", Version: 1, Entries: []TemplateEntity{{ID: "region/us", Section: "proxy-groups", Value: json.RawMessage(`{"name":"G","type":"select","proxies":["DIRECT"]}`)}}}
	intent := &EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Template: &TemplatePlan{TemplateID: "region", Version: 1, Region: &RegionPlan{Mode: "region", Selector: "Pick", Enable: true}, Baseline: base, Mine: base}, Operations: []EditOperation{
		{ID: "dependent", Kind: "update", Section: "proxy-groups", Target: targetID("proxy-groups", "Existing"), Patch: json.RawMessage(`{"proxies":["G"]}`)},
		{ID: "independent", Kind: "update", Section: "proxy-groups", Target: targetID("proxy-groups", "Existing"), Patch: json.RawMessage(`{"hidden":true}`)},
		{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: targetID("proxy-groups", "Existing"), Name: "Personal"},
		{ID: "rule", Kind: "add", Section: "rules", Value: json.RawMessage(`"DOMAIN,example.synthetic,Personal"`)},
	}}
	r, err := SwitchTemplate(intent, TemplatePlan{TemplateID: "original", Version: 1}, true)
	if err != nil {
		t.Fatal(err)
	}
	for i, op := range r.Intent.Operations {
		if (i == 0) != (op.TemplateID == "region") {
			t.Fatalf("unrelated edit paused: %+v", op)
		}
	}
}
