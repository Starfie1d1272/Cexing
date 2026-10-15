package configpipeline

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func routingFixturePlan() RoutingPlan {
	digest, _ := RoutingOverlayDigest(nil)
	scope := RoutingScope{Unknown: "include"}
	aiScope := RoutingScope{Unknown: "exclude", ExcludeRegions: []string{"香港"}}
	return RoutingPlan{Version: 1, Mode: "managed", DefaultOutlet: "default", OverlayRulesDigest: digest,
		Outlets: []RoutingOutlet{{ID: "default", Algorithm: "smart", Scope: scope}, {ID: "ai", Algorithm: "url-test", Scope: aiScope}},
		Routes:  []RoutingRoute{{ID: "ai", Services: []string{"category-ai-!cn"}, Outlet: "ai"}, {ID: "claude", Services: []string{"anthropic", "openai"}, Outlet: "default"}}}
}
func routingRoot(t *testing.T) *yaml.Node {
	t.Helper()
	root, err := RegionMergedSource([]byte(strings.ReplaceAll(regionFixture, "type: ss", "type: ss")), nil)
	if err != nil {
		t.Fatal(err)
	}
	return root
}
func routingGroup(root *yaml.Node, id string) *yaml.Node {
	for _, g := range field(root, "proxy-groups").Content {
		if field(g, "name").Value == RoutingGroupName(id) {
			return g
		}
	}
	return nil
}
func TestRoutingScopeCompositionPriorityAndSmartIsolation(t *testing.T) {
	root := routingRoot(t)
	plan := routingFixturePlan()
	plan.Assignments = map[string]string{"mystery": "美国"}
	plan.Outlets[1].Scope.Regions = []string{"日本", "美国"}
	if err := ApplyRouting(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	if err := validateReferences(root); err != nil {
		t.Fatal(err)
	}
	members := field(routingGroup(root, "ai"), "proxies")
	if len(members.Content) != 2 {
		t.Fatal("multi-country set was not flattened")
	}
	for _, n := range members.Content {
		if n.Value == "HK Alpha" {
			t.Fatal("Hong Kong escaped exclusion")
		}
	}
	intent := &EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []EditOperation{}, Template: &TemplatePlan{TemplateID: "routing", Version: 1, Routing: &plan}}
	if err := ApplySmartPolicy(context.Background(), root, true, intent); err != nil {
		t.Fatal(err)
	}
	if field(routingGroup(root, "ai"), "type").Value != "url-test" {
		t.Fatal("global Smart overrode outlet algorithm")
	}
	// Personal renames use stable binding aliases, not source-name IDs.
	alias := TemplateTarget("routing", RoutingOutletEntityID(RoutingGroupName("ai")))
	intent.Operations = append(intent.Operations, EditOperation{ID: "rename-outlet", Kind: "rename", Section: "proxy-groups", Target: alias, Name: "Renamed managed exit"})
	group := routingGroup(root, "ai")
	set(group, "name", scalar("Renamed managed exit"))
	if err := ApplySmartPolicy(context.Background(), root, true, intent); err != nil {
		t.Fatal(err)
	}
	if field(group, "type").Value != "url-test" {
		t.Fatal("managed algorithm lost after rename")
	}
	rules := field(root, "rules")
	positions := map[string]int{}
	for i, n := range rules.Content {
		positions[n.Value] = i
	}
	specific, aggregate, cn, match := -1, -1, -1, -1
	for rule, i := range positions {
		switch {
		case strings.Contains(rule, "cexing-openai-"):
			specific = i
		case strings.Contains(rule, "cexing-category-ai-not-cn-"):
			aggregate = i
		case strings.HasPrefix(rule, "GEOIP,CN,"):
			cn = i
		case strings.HasPrefix(rule, "MATCH,"):
			match = i
		}
	}
	if specific < 8 || aggregate <= specific || cn <= aggregate || match <= cn {
		t.Fatal("service/domestic/default precedence changed")
	}
	if field(root, "rules").Content[0].Value != "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve" {
		t.Fatal("LAN priority changed")
	}
}
func TestRoutingUnknownEmptyAndOverlayFence(t *testing.T) {
	plan := routingFixturePlan()
	root := routingRoot(t)
	if err := ApplyRouting(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	ai := field(routingGroup(root, "ai"), "proxies")
	if len(ai.Content) != 1 || ai.Content[0].Value != "JP Beta" {
		t.Fatal("unknown included as non-Hong Kong")
	}
	plan.Outlets[1].Scope.Regions = []string{"美国"}
	if err := ApplyRouting(context.Background(), routingRoot(t), plan); err == nil {
		t.Fatal("empty scope accepted")
	}
	intent := &EditIntent{Template: &TemplatePlan{Routing: &plan}}
	request := Request{Intent: intent}
	if err := CheckRoutingOverlay(request); err != nil {
		t.Fatal(err)
	}
	request.Overlays = [][]byte{[]byte("rules: [MATCH,DIRECT]\n")}
	if err := CheckRoutingOverlay(request); err == nil {
		t.Fatal("changed Merge rules silently shadowed")
	}
	// Subscription-default removal compiles fresh original input, not generated YAML.
	original := routingRoot(t)
	before := fingerprint(original)
	plan.Mode = "subscription"
	plan.DefaultOutlet = ""
	plan.Outlets = nil
	plan.Routes = nil
	if err := ApplyRouting(context.Background(), original, plan); err != nil || fingerprint(original) != before {
		t.Fatal("subscription mode changed original")
	}
}
func TestRoutingFallbackOrderAndFailClosedProvider(t *testing.T) {
	plan := routingFixturePlan()
	plan.Outlets = plan.Outlets[:1]
	plan.Routes = nil
	plan.Outlets[0].Algorithm = "fallback"
	plan.Outlets[0].Order = []string{"JP Beta", "HK Alpha", "mystery"}
	if err := ApplyRouting(context.Background(), routingRoot(t), plan); err != nil {
		t.Fatal(err)
	}
	root := routingRoot(t)
	plan.Outlets[0].Scope.ExcludeRegions = []string{"香港"}
	if err := ApplyRouting(context.Background(), root, plan); err == nil {
		t.Fatal("stale fallback order crossed exclusion")
	}
	root = routingRoot(t)
	set(root, "proxy-providers", &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: []*yaml.Node{scalar("public"), {Kind: yaml.MappingNode, Tag: "!!map"}}})
	plan.Outlets[0].Scope.ExcludeRegions = nil
	plan.Outlets[0].Order = append(plan.Outlets[0].Order, "US provider")
	if err := ApplyRouting(context.Background(), root, plan); err == nil {
		t.Fatal("missing provider treated as empty")
	}
	plan.ResolvedProviders = map[string][]string{"public": {"US provider"}}
	if err := ApplyRouting(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	group := routingGroup(root, "default")
	if field(group, "empty-fallback").Value != "REJECT" || len(field(group, "proxies").Content) != 4 {
		t.Fatal("fallback order or reject changed")
	}
}
func TestRoutingOptionsPreserveUnknownAndRejectBypass(t *testing.T) {
	plan := routingFixturePlan()
	plan.Outlets[0].Options = map[string]json.RawMessage{"future-valid-field": json.RawMessage(`{"retained":true}`), "collectdata": json.RawMessage(`false`), "tolerance": json.RawMessage(`50`)}
	root := routingRoot(t)
	if err := ApplyRouting(context.Background(), root, plan); err != nil {
		t.Fatal(err)
	}
	if field(routingGroup(root, "default"), "future-valid-field") == nil {
		t.Fatal("unknown option discarded")
	}
	plan.Outlets[0].Options["include-all"] = json.RawMessage(`true`)
	if plan.Validate() == nil {
		t.Fatal("raw options bypassed scope")
	}
	delete(plan.Outlets[0].Options, "include-all")
	plan.Outlets[0].Options["sample-rate"] = json.RawMessage(`1.1`)
	if plan.Validate() == nil {
		t.Fatal("invalid sample rate")
	}
}
