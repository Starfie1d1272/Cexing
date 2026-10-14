package configpipeline

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestSmartAutoConvertsOnlyAutomaticGroupsAfterMerge(t *testing.T) {
	const original = `proxies:
  - {name: a, type: direct}
  - {name: b, type: direct}
proxy-groups:
  - {name: automatic, type: url-test, proxies: [a, b], tolerance: 40}
  - {name: balance, type: load-balance, proxies: [a, b], strategy: round-robin}
  - {name: manual, type: select, proxies: [automatic, balance, DIRECT]}
  - {name: fallback, type: fallback, proxies: [a, b]}
rules: ["MATCH,manual"]
`
	const overlay = `proxy-groups:
  - {name: automatic, type: url-test, proxies: [b, a], tolerance: 30}
  - {name: balance, type: load-balance, proxies: [a, b], strategy: round-robin}
  - {name: manual, type: select, proxies: [automatic, balance, DIRECT]}
  - {name: fallback, type: fallback, proxies: [a, b]}
rules: ["MATCH,manual"]
`
	c := Compiler{Platform: func(context.Context, *yaml.Node) error { return nil },
		Validate: func(context.Context, []byte) error { return nil }}
	request := Request{Original: []byte(original), Overlays: [][]byte{[]byte(overlay)}, Strategy: SmartAuto}
	converted, err := c.Compile(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := yaml.Unmarshal(converted.YAML, &doc); err != nil {
		t.Fatal(err)
	}
	groups := doc["proxy-groups"].([]any)
	auto := groups[0].(map[string]any)
	balance := groups[1].(map[string]any)
	if auto["type"] != "smart" || auto["uselightgbm"] != true || auto["tolerance"] != 30 ||
		!equalMembers(auto["proxies"], "b", "a") || balance["type"] != "load-balance" ||
		balance["strategy"] != "round-robin" || auto["collectdata"] != false || auto["prefer-asn"] != false {
		t.Fatal("automatic group conversion lost policy or ordered members")
	}
	if groups[2].(map[string]any)["type"] != "select" || groups[3].(map[string]any)["type"] != "fallback" ||
		!equalMembers(groups[2].(map[string]any)["proxies"], "automatic", "balance", "DIRECT") ||
		!equalMembers(doc["rules"], "MATCH,manual") {
		t.Fatal("manual selection or rule references changed")
	}
	without, err := c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{[]byte(overlay)}})
	if err != nil || !strings.Contains(string(without.YAML), "type: url-test") ||
		!strings.Contains(string(without.YAML), "type: load-balance") {
		t.Fatal("disabled conversion did not restore source and Merge types", err)
	}
	if strings.Contains(string(converted.Original), "uselightgbm") || string(converted.Original) != original {
		t.Fatal("original subscription changed")
	}
}

func equalMembers(value any, expected ...string) bool {
	items, ok := value.([]any)
	if !ok || len(items) != len(expected) {
		return false
	}
	for i, item := range items {
		if item != expected[i] {
			return false
		}
	}
	return true
}

func TestSmartIntentChoicesOverrideDefaultAndRemainPrivate(t *testing.T) {
	source := editFixture(t)
	automatic := editTarget(t, source, "proxy-groups", 1)
	balanced := editTarget(t, source, "proxy-groups", 2)
	plan := editPlan(t, source)
	plan.Operations = []EditOperation{}
	plan.SmartGroups = map[string]bool{automatic.Item.ID: false, balanced.Item.ID: true}
	c := editCompiler()
	request := Request{Original: source, Intent: plan, Strategy: func(ctx context.Context, root *yaml.Node) error { return ApplySmartPolicy(ctx, root, true, plan) }}
	r, e := c.Compile(context.Background(), request)
	if e != nil {
		t.Fatal(e)
	}
	root, _ := parse(r.YAML)
	groups := field(root, "proxy-groups")
	if field(groups.Content[1], "type").Value != "url-test" || field(groups.Content[2], "type").Value != "smart" || field(groups.Content[2], "strategy") != nil {
		t.Fatal("per-group exceptions ignored")
	}
	if string(r.Original) != string(source) {
		t.Fatal("source changed")
	}
	plan.SmartGroups = map[string]bool{balanced.Item.ID: false}
	r, e = c.Compile(context.Background(), request)
	if e != nil {
		t.Fatal(e)
	}
	root, _ = parse(r.YAML)
	groups = field(root, "proxy-groups")
	if field(groups.Content[2], "type").Value != "load-balance" || field(groups.Content[2], "strategy").Value != "round-robin" {
		t.Fatal("opt-in reversal lost original algorithm")
	}
	// Global disabled still permits the user's explicit per-subscription opt-in.
	plan.SmartGroups[balanced.Item.ID] = true
	request.Strategy = func(ctx context.Context, root *yaml.Node) error { return ApplySmartPolicy(ctx, root, false, plan) }
	r, e = c.Compile(context.Background(), request)
	if e != nil {
		t.Fatal(e)
	}
	root, _ = parse(r.YAML)
	groups = field(root, "proxy-groups")
	if field(groups.Content[1], "type").Value != "url-test" || field(groups.Content[2], "type").Value != "smart" {
		t.Fatal("default/explicit precedence wrong")
	}
}

func TestSmartPolicyExistingSmartSelectorNewDeletedAndDisabledIntent(t *testing.T) {
	source := []byte(`proxies: [{name: a, type: direct}]
proxy-groups:
 - {name: existing, type: smart, proxies: [a], uselightgbm: false, collectdata: true, prefer-asn: true}
 - {name: manual, type: select, proxies: [a]}
 - {name: new, type: url-test, proxies: [a]}
rules: ["MATCH,manual"]
`)
	manual := editTarget(t, source, "proxy-groups", 1)
	plan := editPlan(t, source)
	plan.Operations = []EditOperation{}
	plan.SmartGroups = map[string]bool{manual.Item.ID: true, "deleted-upstream-id": true}
	root, e := parse(source)
	if e != nil {
		t.Fatal(e)
	}
	before := fingerprint(field(root, "proxy-groups").Content[0])
	preview, e := PreviewSmartPolicy(root, true, plan)
	if e != nil || len(preview) != 1 || preview[0].Before != "url-test" || preview[0].After != "smart" {
		t.Fatal("new/deleted policy", e)
	}
	if fingerprint(field(root, "proxy-groups").Content[0]) != before {
		t.Fatal("preview mutates")
	}
	if e = ApplySmartPolicy(context.Background(), root, true, plan); e != nil {
		t.Fatal(e)
	}
	groups := field(root, "proxy-groups")
	if fingerprint(groups.Content[0]) != before || field(groups.Content[1], "type").Value != "select" {
		t.Fatal("existing Smart/manual overwritten")
	}
	plan.Disabled = true
	root, _ = parse(editFixture(t))
	preview, e = PreviewSmartPolicy(root, true, plan)
	if e != nil || preview[1].After != "load-balance" {
		t.Fatal("disabled plan retains opt-in", e)
	}
	empty, _ := parse([]byte("proxies: [{name: a, type: direct}]\n"))
	preview, e = PreviewSmartPolicy(empty, true, plan)
	if e != nil || len(preview) != 0 {
		t.Fatal("no groups treated as fault", e)
	}
}

func TestSmartChoiceRetainsSourceIdentityAcrossRenameChainAndUndo(t *testing.T) {
	source := editFixture(t)
	for _, index := range []int{1, 2} {
		t.Run([]string{"url-test-exception", "balance-opt-in"}[index-1], func(t *testing.T) {
			target := editTarget(t, source, "proxy-groups", index)
			choice := index == 2
			plan := editPlan(t, source, EditOperation{ID: "rename", Kind: "rename", Section: "proxy-groups", Target: target.Item.ID, Expected: target.Item.Revision, Name: "renamed"})
			plan.SmartGroups = map[string]bool{target.Item.ID: choice}
			c := editCompiler()
			r, e := c.Compile(context.Background(), Request{Original: source, Intent: plan, Strategy: func(ctx context.Context, root *yaml.Node) error { return ApplySmartPolicy(ctx, root, true, plan) }})
			if e != nil {
				t.Fatal(e)
			}
			root, _ := parse(r.YAML)
			group := field(root, "proxy-groups").Content[index]
			want := "url-test"
			if choice {
				want = "smart"
			}
			if field(group, "name").Value != "renamed" || field(group, "type").Value != want {
				t.Fatal("rename lost explicit Smart choice")
			}
			view, e := (Compiler{}).SmartPreview(context.Background(), Request{Original: source, Intent: plan}, true)
			if e != nil {
				t.Fatal(e)
			}
			row := view[index-1]
			if row.ChoiceID != target.Item.ID || row.ID == row.ChoiceID || !row.Override || row.After != want {
				t.Fatal("UI cannot preserve logical choice", row)
			}
			second, e := (Compiler{}).EditTarget(context.Background(), Request{Original: source, Intent: plan}, "proxy-groups", row.ID)
			if e != nil {
				t.Fatal(e)
			}
			plan.Operations = append(plan.Operations, EditOperation{ID: "rename-again", Kind: "rename", Section: "proxy-groups", Target: row.ID, Expected: second.Item.Revision, Name: "renamed-twice"})
			encodedBefore, _ := json.Marshal(plan)
			view, e = (Compiler{}).SmartPreview(context.Background(), Request{Original: source, Intent: plan}, true)
			if e != nil || view[index-1].ChoiceID != target.Item.ID || view[index-1].After != want {
				t.Fatal("rename chain lost identity", e, view)
			}
			encodedAfter, _ := json.Marshal(plan)
			if string(encodedBefore) != string(encodedAfter) {
				t.Fatal("preview changed durable intent")
			}
			// Flip the checkbox through its stable choiceId, then undo the rename.
			plan.SmartGroups[row.ChoiceID] = !choice
			plan.Operations = []EditOperation{}
			view, e = (Compiler{}).SmartPreview(context.Background(), Request{Original: source, Intent: plan}, true)
			if e != nil {
				t.Fatal(e)
			}
			if !view[index-1].Override || view[index-1].ChoiceID != target.Item.ID || (view[index-1].After == "smart") != (!choice) {
				t.Fatal("undo lost checkbox choice", view)
			}
			upstream, _ := parse(source)
			groups := field(upstream, "proxy-groups")
			groups.Content = append(groups.Content[:index], groups.Content[index+1:]...)
			updated, _ := yaml.Marshal(upstream)
			if _, e = (Compiler{}).SmartPreview(context.Background(), Request{Original: updated, Intent: plan}, true); e != nil {
				t.Fatal("dormant choice became failure", e)
			}
			view, e = (Compiler{}).SmartPreview(context.Background(), Request{Original: source, Intent: plan}, true)
			if e != nil || !view[index-1].Override || view[index-1].ChoiceID != target.Item.ID {
				t.Fatal("reappearing group lost choice", e)
			}
		})
	}
}
