package main

import (
	"core/configpipeline"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedRoutingWorkerPublicationAndUpdateFailure(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), syntheticRoutingMMDB(t), 0600); err != nil {
		t.Fatal(err)
	}
	original := "proxies: [{name: JP fixture, type: socks5, server: 192.0.2.1, port: 1080}, {name: HK fixture, type: socks5, server: 192.0.2.2, port: 1080}]\nproxy-groups: [{name: Main, type: select, proxies: [JP fixture, HK fixture]}]\nrules: ['MATCH,Main']\nx-retained: {future: true}\n"
	catalog, err := executeVersionAction(home, versionAction{Op: "routing-catalogue", Original: original})
	if err != nil || catalog.RoutingCatalogue == nil {
		t.Fatal(err)
	}
	p := &configpipeline.RoutingPlan{Version: 1, Mode: "managed", DefaultOutlet: "default", OverlayRulesDigest: catalog.RoutingCatalogue.OverlayRulesDigest,
		Outlets: []configpipeline.RoutingOutlet{{ID: "default", Algorithm: "smart", Scope: configpipeline.RoutingScope{Unknown: "include"}}, {ID: "ai", Algorithm: "fallback", Scope: configpipeline.RoutingScope{Unknown: "exclude", ExcludeRegions: []string{"香港"}}, Order: []string{"JP fixture"}}}, Routes: []configpipeline.RoutingRoute{{ID: "ai", Services: []string{"category-ai-!cn"}, Outlet: "ai"}}}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "routing", Version: 1, Routing: p}}
	action := versionAction{Op: "stage", ProfileID: "routing.yaml", Original: original, Metadata: `{}`, EditIntent: intent, SmartConversion: true}
	staged, err := executeVersionAction(home, action)
	if err != nil || staged.Version == nil {
		t.Fatal("real compiler stage", err)
	}
	bytes, err := os.ReadFile(staged.Version.Path)
	if err != nil || !strings.Contains(string(bytes), "type: fallback") || !strings.Contains(string(bytes), "x-retained:") {
		t.Fatal("generated fields", err)
	}
	var source struct {
		EditIntent *configpipeline.EditIntent
	}
	raw, _ := os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "source.json"))
	if json.Unmarshal(raw, &source) != nil || source.EditIntent.Template.Routing == nil || source.EditIntent.Template.Baseline == nil {
		t.Fatal("routing provenance lost")
	}
	rawOriginal, _ := os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "original.yaml"))
	if string(rawOriginal) != original {
		t.Fatal("original changed")
	}
	if _, err = executeVersionAction(home, versionAction{Op: "commit", ProfileID: "routing.yaml", VersionID: staged.Version.ID, Active: true}); err != nil {
		t.Fatal(err)
	}
	action.Expected = staged.Version.ID
	action.EditIntent = source.EditIntent
	action.Original = strings.ReplaceAll(original, "JP fixture", "unknown fixture")
	if failed, failure := executeVersionAction(home, action); failure == nil && failed.Error == "" {
		t.Fatal("empty AI scope was published")
	}
	state, err := executeVersionAction(home, versionAction{Op: "read"})
	if err != nil || state.State.Current.ID != staged.Version.ID {
		t.Fatal("failed update changed running pointer")
	}
	action.Original = original
	action.Overlay = "rules: ['MATCH,DIRECT']\n"
	if failed, failure := executeVersionAction(home, action); failure == nil && failed.Error == "" {
		t.Fatal("unacknowledged Merge conflict accepted")
	}
}

// A one-node empty MMDB tree is sufficient to exercise the real GEOIP parser.
func syntheticRoutingMMDB(t *testing.T) []byte {
	t.Helper()
	data, err := base64.StdEncoding.DecodeString("AAABAAABAAAAAAAAAAAAAAAAAAAAAKvN701heE1pbmQuY29t6Upub2RlX2NvdW50wQFLcmVjb3JkX3NpemWhGEppcF92ZXJzaW9uoQRNZGF0YWJhc2VfdHlwZVFzeW50aGV0aWMtQ291bnRyeUlsYW5ndWFnZXMABFtiaW5hcnlfZm9ybWF0X21ham9yX3ZlcnNpb26hAltiaW5hcnlfZm9ybWF0X21pbm9yX3ZlcnNpb26gS2J1aWxkX2Vwb2NoAQIBS2Rlc2NyaXB0aW9u4A==")
	if err != nil {
		t.Fatal(err)
	}
	return data
}
