package profiletemplates

import (
	"context"
	"core/configpipeline"
	"gopkg.in/yaml.v3"
	"strings"
	"testing"
)

// The unified region template must reuse the pre-existing all-node strategy,
// retain its stable authoring identity, and still reject undersized groups.
func TestRegionAllTemplatePrepareAndMapping(t *testing.T) {
	source := strings.Replace(fixture, "proxy-groups:", "  - {name: JP-two, type: ss, server: 192.0.2.2, port: 443, cipher: aes-128-gcm, password: synthetic}\nproxy-groups:", 1)
	source = strings.Replace(source, "proxies: [US-one]", "proxies: [US-one, JP-two]", 1)
	root := regionAllRoot(t, source)
	plan := Plan{TemplateID: "region", Version: 1, Region: &configpipeline.RegionPlan{Mode: "all", Selector: "Pick", Enable: true, Assignments: map[string]string{"US-one": "日本"}}}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "region", Version: 1, Region: plan.Region}}
	if err := configpipeline.CheckEditIntent(intent); err != nil {
		t.Fatal(err)
	}
	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}
	base, targets, err := Prepare(context.Background(), root, plan)
	if err != nil {
		t.Fatal(err)
	}
	if len(base.Entries) != 2 || targets[TemplateTarget("region", "region/all")] == nil || targets[TemplateTarget("region", "region/entry")] == nil {
		t.Fatal("all-node authoring identities were not retained")
	}
	if _, err = CaptureEdited(context.Background(), root, base, targets); err != nil {
		t.Fatal(err)
	}
	if field(root, "rules").Content[1].Value != "MATCH,Pick" {
		t.Fatal("subscription rules changed")
	}
	plan.Region.Mode = "region"
	if _, _, err = Prepare(context.Background(), regionAllRoot(t, source), plan); err != nil {
		t.Fatal(err)
	}
	plan.Region.Mode = "all"
	if _, _, err = Prepare(context.Background(), regionAllRoot(t, fixture), plan); err == nil {
		t.Fatal("all-node group accepted one node")
	}
	plan.Region.Mode = "unknown"
	if plan.Validate() == nil {
		t.Fatal("unknown region mode accepted")
	}
}

func regionAllRoot(t *testing.T, source string) *yaml.Node {
	t.Helper()
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(source), &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Content[0]
}
