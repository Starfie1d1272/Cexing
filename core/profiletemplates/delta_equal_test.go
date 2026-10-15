package profiletemplates

import (
	"encoding/json"
	"testing"
)

func TestEqualSnapshotsPreservesLargeIntegersAndSemanticOrdering(t *testing.T) {
	makeSnapshot := func(value string) *TemplateSnapshot {
		return &TemplateSnapshot{TemplateID: "region", Version: 1, Entries: []Entity{{ID: "region/us", Section: "proxy-groups", Value: json.RawMessage(value)}}}
	}
	a := makeSnapshot(`{"name":"group","x-advanced":9007199254740992}`)
	b := makeSnapshot(`{"name":"group","x-advanced":9007199254740993}`)
	if EqualSnapshots(a, b) {
		t.Fatal("large advanced integers were rounded into false equality")
	}
	c := makeSnapshot(`{ "x-advanced": 9007199254740992, "name": "group" }`)
	if !EqualSnapshots(a, c) {
		t.Fatal("mapping formatting/order treated as semantic change")
	}
	a.Deleted = []string{"region/hk", "region/jp"}
	c.Deleted = []string{"region/jp", "region/hk"}
	if !EqualSnapshots(a, c) {
		t.Fatal("tombstone order treated as semantic change")
	}
	c.Entries = append(c.Entries, Entity{ID: "region/entry", Section: "proxy-groups", Value: json.RawMessage(`{"name":"entry"}`)})
	if EqualSnapshots(a, c) {
		t.Fatal("extra entity ignored")
	}
}
