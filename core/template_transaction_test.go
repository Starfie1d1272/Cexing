package main

import (
	"context"
	"core/configpipeline"
	"core/profiletemplates"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTemplateProvenanceStagesPublishesAndRebasesThroughOriginalStore(t *testing.T) {
	home := t.TempDir()
	os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600)
	original := "proxies: [{name: synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\nproxy-groups: [{name: Main, type: select, proxies: [synthetic]}]\nrules: ['MATCH,Main']\n"
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "applied-draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "Main"}}
	alias := profiletemplates.TemplateTarget("ai", "ai/openai")
	request, e := editorReadRequest(home, versionAction{Original: original, EditIntent: intent}, "")
	if e != nil {
		t.Fatal(e)
	}
	target, e := (configpipeline.Compiler{PrepareTemplate: editorTemplatePrepare(home)}).EditTarget(context.Background(), request, "rules", alias)
	if e != nil {
		t.Fatal(e)
	}
	intent.Operations = []configpipeline.EditOperation{{ID: "delete", Kind: "delete", Section: "rules", Target: alias, Expected: target.Item.Revision}}
	a := versionAction{Op: "stage", ProfileID: "one.yaml", Original: original, Metadata: `{}`, EditIntent: intent}
	identity, e := editorIdentity(home, a, "")
	if e != nil {
		t.Fatal("identity must accept canonical template aliases", e)
	}
	staged, e := executeVersionAction(home, a)
	if e != nil || staged.Version == nil {
		t.Fatal("stage", e, staged.Error)
	}
	var source struct{ EditIntent *configpipeline.EditIntent }
	raw, _ := os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "source.json"))
	if json.Unmarshal(raw, &source) != nil || source.EditIntent.Template.Baseline == nil || source.EditIntent.Template.Mine == nil || len(source.EditIntent.Template.Mine.Deleted) != 1 {
		t.Fatal("stage lost Base/Mine/tombstone")
	}
	if intent.Template.Baseline != nil || intent.Template.Mine != nil {
		t.Fatal("stage mutated unpublished intent")
	}
	a.EditIntent = source.EditIntent
	after, e := editorIdentity(home, a, "")
	if e != nil || after != identity {
		t.Fatal("own captured provenance changed editor identity", e)
	}
	if _, e = executeVersionAction(home, versionAction{Op: "commit", VersionID: staged.Version.ID, ProfileID: "one.yaml", Active: true}); e != nil {
		t.Fatal(e)
	}
	current := staged.Version.ID
	a.Expected = current
	a.Original = original + "x-upstream: unchanged-personal\n"
	next, e := executeVersionAction(home, a)
	if e != nil || next.Version == nil {
		t.Fatal("subscription restage", e, next.Error)
	}
	raw, _ = os.ReadFile(filepath.Join(filepath.Dir(next.Version.Path), "source.json"))
	json.Unmarshal(raw, &source)
	if len(source.EditIntent.Template.Mine.Deleted) != 1 {
		t.Fatal("update lost tombstone")
	}
	a.Original = "rules: ['MATCH,Missing']\n"
	failed, e := executeVersionAction(home, a)
	if e == nil && failed.Error == "" {
		t.Fatal("invalid update accepted")
	}
	state, e := executeVersionAction(home, versionAction{Op: "read"})
	if e != nil || state.State.Current.ID != current {
		t.Fatal("failed update published")
	}
	raw, _ = os.ReadFile(staged.Version.Path)
	if strings.Contains(string(raw), "DOMAIN-SUFFIX,openai.com,") {
		t.Fatal("deleted generated rule reappeared")
	}
}
