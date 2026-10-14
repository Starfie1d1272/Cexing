package profiletemplates

import (
	"context"
	"core/configpipeline"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func entry(id, section, value string) Entity {
	return Entity{ID: id, Section: section, Value: json.RawMessage(value)}
}
func snap(version int, entries ...Entity) TemplateSnapshot {
	return TemplateSnapshot{TemplateID: "ai", Version: version, Entries: entries}
}
func mapping(t *testing.T, s *TemplateSnapshot, id string) map[string]any {
	t.Helper()
	for _, e := range s.Entries {
		if e.ID == id {
			var v map[string]any
			if err := json.Unmarshal(e.Value, &v); err != nil {
				t.Fatal(err)
			}
			return v
		}
	}
	t.Fatal("missing synthetic entity", id)
	return nil
}

func TestUpdateFieldsUnknownKeysAndTwoUpgrades(t *testing.T) {
	base := snap(1, entry("group/ai", "proxy-groups", `{"name":"AI","type":"select","proxies":["one"],"x-future":{"left":1,"right":2}}`), entry("ai/web", "rules", `"DOMAIN,synthetic.example,AI"`))
	mine := snap(1, entry("group/ai", "proxy-groups", `{"name":"Personal","type":"select","proxies":["one"],"x-future":{"left":9,"right":2}}`), entry("ai/web", "rules", `"DOMAIN,synthetic.example,AI"`))
	next := snap(2, entry("group/ai", "proxy-groups", `{"name":"AI","type":"select","proxies":["two"],"x-future":{"left":1,"right":3,"unknown":true}}`), entry("ai/web", "rules", `"DOMAIN,new-synthetic.example,AI"`))
	before, _ := json.Marshal([]TemplateSnapshot{base, mine, next})
	result, err := PreviewUpdate(context.Background(), UpdateRequest{Kind: "template", Base: base, Mine: mine, Next: next})
	if err != nil || !result.Ready {
		t.Fatal(result, err)
	}
	value := mapping(t, result.Candidate, "group/ai")
	if value["name"] != "Personal" || !reflect.DeepEqual(value["proxies"], []any{"two"}) {
		t.Fatal("personal rename or template members lost", value)
	}
	future := value["x-future"].(map[string]any)
	if future["left"] != float64(9) || future["right"] != float64(3) || future["unknown"] != true {
		t.Fatal("unknown nested fields lost", value)
	}
	version3 := snap(3, entry("group/ai", "proxy-groups", `{"name":"AI","type":"select","proxies":["three"],"x-future":{"left":1,"right":4,"unknown":true}}`), next.Entries[1])
	restartedBytes, _ := json.Marshal(result.Candidate)
	var restarted TemplateSnapshot
	json.Unmarshal(restartedBytes, &restarted)
	again, err := PreviewUpdate(context.Background(), UpdateRequest{Kind: "template", Base: next, Mine: restarted, Next: version3})
	if err != nil || !again.Ready || mapping(t, again.Candidate, "group/ai")["name"] != "Personal" {
		t.Fatal("second upgrade/restart lost edit", err)
	}
	after, _ := json.Marshal([]TemplateSnapshot{base, mine, next})
	if string(before) != string(after) {
		t.Fatal("inputs mutated")
	}
}

func TestUpdateConflictsDecisionsAndDeletedTombstones(t *testing.T) {
	a := entry("ai/web", "rules", `"DOMAIN,synthetic.example,AI"`)
	b := entry("ai/web", "rules", `"DOMAIN,synthetic.example,Personal"`)
	c := entry("ai/web", "rules", `"DOMAIN,new.example,AI"`)
	request := UpdateRequest{Kind: "template", Base: snap(1, a), Mine: snap(1, b), Next: snap(2, c)}
	conflict, err := PreviewUpdate(context.Background(), request)
	if err != nil || conflict.Ready || conflict.Candidate != nil || len(conflict.Conflicts) != 1 {
		t.Fatal("unresolved conflict produced candidate", conflict, err)
	}
	for _, choice := range []string{"mine", "template"} {
		request.Decisions = map[string]string{conflict.Conflicts[0].ID: choice}
		result, err := PreviewUpdate(context.Background(), request)
		if err != nil || !result.Ready {
			t.Fatal(err)
		}
		expected := b.Value
		if choice == "template" {
			expected = c.Value
		}
		if string(result.Candidate.Entries[0].Value) != string(expected) {
			t.Fatal("wrong conflict choice")
		}
	}
	request.Next = snap(2, entry("ai/web", "rules", `"DOMAIN,third.example,AI"`))
	if _, err = PreviewUpdate(context.Background(), request); err == nil {
		t.Fatal("stale choice applied to changed input")
	}
	request = UpdateRequest{Kind: "template", Base: snap(1, a), Mine: snap(1), Next: snap(2)}
	deleted, err := PreviewUpdate(context.Background(), request)
	if err != nil || !deleted.Ready || len(deleted.Candidate.Deleted) != 1 {
		t.Fatal("personal tombstone lost", err)
	}
	restored, err := PreviewUpdate(context.Background(), UpdateRequest{Kind: "template", Base: snap(2), Mine: *deleted.Candidate, Next: snap(3, c)})
	if err != nil || !restored.Ready || len(restored.Candidate.Entries) != 0 {
		t.Fatal("upstream re-add resurrected personal deletion", err)
	}
	// Missing is different from JSON null; changing a field to null conflicts
	// with deleting it in the new template rather than silently discarding it.
	request = UpdateRequest{Kind: "template", Base: snap(1, entry("group/a", "proxy-groups", `{"name":"AI","unknown":1}`)), Mine: snap(1, entry("group/a", "proxy-groups", `{"name":"AI","unknown":null}`)), Next: snap(2, entry("group/a", "proxy-groups", `{"name":"AI"}`))}
	result, err := PreviewUpdate(context.Background(), request)
	if err != nil || result.Ready || len(result.Conflicts) != 1 {
		t.Fatal("null/deletion conflict missed", err)
	}
}

func TestUpdateOrderingIndependentInsertionsAndKinds(t *testing.T) {
	a, b, c := entry("rule/a", "rules", `"MATCH,A"`), entry("rule/b", "rules", `"MATCH,B"`), entry("rule/c", "rules", `"MATCH,C"`)
	added := entry("rule/new", "rules", `"MATCH,N"`)
	request := UpdateRequest{Kind: "template", Base: snap(1, a, b, c), Mine: snap(1, b, a, c), Next: snap(2, a, added, b, c)}
	result, err := PreviewUpdate(context.Background(), request)
	if err != nil || !result.Ready {
		t.Fatal(result, err)
	}
	ids := []string{}
	for _, e := range result.Candidate.Entries {
		ids = append(ids, e.ID)
	}
	if !reflect.DeepEqual(ids, []string{"rule/new", "rule/b", "rule/a", "rule/c"}) {
		t.Fatal("personal order or independent insertion lost", ids)
	}
	request.Next = snap(2, a, c, b)
	conflict, err := PreviewUpdate(context.Background(), request)
	if err != nil || conflict.Ready || len(conflict.Conflicts) != 1 || conflict.Conflicts[0].Kind != "order" {
		t.Fatal("simultaneous reorder conflict missed", err)
	}
	request.Kind = "provider"
	if _, err := PreviewUpdate(context.Background(), request); err == nil {
		t.Fatal("provider refresh treated as template upgrade")
	}
	request.Kind = "subscription"
	if _, err := PreviewUpdate(context.Background(), request); err == nil {
		t.Fatal("subscription refresh advanced template version")
	}
	request.Next = snap(1, a, b, c)
	if result, err := PreviewUpdate(context.Background(), request); err != nil || !result.Ready {
		t.Fatal("same-version subscription rebase failed", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := PreviewUpdate(ctx, request); err == nil {
		t.Fatal("cancelled update yielded a candidate")
	}
	bad := request
	bad.Next = snap(1, entry("rule/a", "rules", `{"same":1,"same":2}`))
	if _, err := PreviewUpdate(context.Background(), bad); err == nil {
		t.Fatal("duplicate JSON/YAML keys accepted")
	}
	serialized, _ := json.Marshal(conflict.Conflicts)
	if strings.Contains(string(serialized), "MATCH,") {
		t.Fatal("conflict summary leaked values")
	}
}

func TestPreparedTemplateCapturesOnlyOwnedNodesAndFencesBindings(t *testing.T) {
	ctx := context.Background()
	root, err := configpipeline.LayeredMergeSource([]byte(fixture), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	plan := Plan{TemplateID: "ai", Version: 1, TargetGroup: "Pick"}
	baseline, targets, err := Prepare(ctx, root, plan)
	if err != nil {
		t.Fatal(err)
	}
	if len(baseline.Entries) != 8 || len(targets) != 8 {
		t.Fatal("upstream rows leaked into owned baseline")
	}
	alias := TemplateTarget("ai", baseline.Entries[0].ID)
	node := targets[alias]
	node.Value = "DOMAIN,synthetic.example,Pick"
	personal, err := CaptureEdited(ctx, root, baseline, targets)
	if err != nil || string(personal.Entries[0].Value) == string(baseline.Entries[0].Value) {
		t.Fatal("edit lost", err)
	}
	// The normal editor replaces scalar nodes; it must update its alias binding.
	rules := field(root, "rules")
	replacement := *node
	rules.Content[0] = &replacement
	if _, err := CaptureEdited(ctx, root, baseline, targets); err == nil {
		t.Fatal("stale replaced-node binding accepted")
	}
	targets[alias] = rules.Content[0]
	if _, err := CaptureEdited(ctx, root, baseline, targets); err != nil {
		t.Fatal(err)
	}
	rules.Content = rules.Content[1:]
	targets[alias] = nil
	deleted, err := CaptureEdited(ctx, root, baseline, targets)
	if err != nil || len(deleted.Deleted) != 1 {
		t.Fatal("explicit tombstone lost", err)
	}
	regionRoot, err := configpipeline.LayeredMergeSource([]byte(fixture), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	region, _, err := Prepare(ctx, regionRoot, Plan{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "region", Selector: "Pick", Enable: true}})
	if err != nil || len(region.Entries) != 2 {
		t.Fatal("region owned capture failed", err)
	}
}

func TestIndependentReordersMergeWithoutConflict(t *testing.T) {
	a, b, c, d := entry("rule/a", "rules", `"MATCH,A"`), entry("rule/b", "rules", `"MATCH,B"`), entry("rule/c", "rules", `"MATCH,C"`), entry("rule/d", "rules", `"MATCH,D"`)
	result, err := PreviewUpdate(context.Background(), UpdateRequest{Kind: "template", Base: snap(1, a, b, c, d), Mine: snap(1, b, a, c, d), Next: snap(2, a, b, d, c)})
	if err != nil || !result.Ready {
		t.Fatal("independent moves conflicted", result, err)
	}
	ids := []string{}
	for _, e := range result.Candidate.Entries {
		ids = append(ids, e.ID)
	}
	if !reflect.DeepEqual(ids, []string{"rule/b", "rule/a", "rule/d", "rule/c"}) {
		t.Fatal(ids)
	}
}
