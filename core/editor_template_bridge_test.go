package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"core/configpipeline"
)

func TestEditorTemplateListsAndCompilationUseSamePersonalView(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := "proxies: [{name: a, type: direct}]\nproxy-groups: [{name: pick, type: select, proxies: [a]}]\nrules: ['MATCH,pick']\n"
	plan := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft-1", SourceRevision: "authoring", Operations: []configpipeline.EditOperation{}, Template: &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "pick"}}
	action := versionAction{Op: "editor-list", Original: original, EditIntent: plan}
	view, e := executeVersionAction(home, action)
	if e != nil || view.Editable == nil {
		t.Fatal("template list unavailable", e, view.Error)
	}
	rules := view.Editable.Sections[3].Items
	if len(rules) != 9 {
		t.Fatal("template absent from authoring view", len(rules))
	}
	action.Op = "edit-target"
	action.EditSection = "rules"
	action.EditTarget = rules[0].ID
	target, e := executeVersionAction(home, action)
	if e != nil || target.EditTarget == nil || !strings.Contains(string(target.EditTarget.Value), "chatgpt.com") {
		t.Fatal("target not from same template view", e)
	}
	plan.Operations = []configpipeline.EditOperation{{ID: "personal-delete", Kind: "delete", Section: "rules", Target: rules[0].ID, Expected: rules[0].Revision}}
	action.Op = "editor-list"
	view, e = executeVersionAction(home, action)
	if e != nil || len(view.Editable.Sections[3].Items) != 8 {
		t.Fatal("personal edit overwritten by template", e)
	}
	result, _, e := compileLayeredMergeWithIntent(home, original, "", "", "", true, nil, plan)
	if e != nil || strings.Contains(string(result.YAML), "chatgpt.com") || !strings.Contains(string(result.YAML), "openai.com") || string(result.Original) != original {
		t.Fatal("compile/editor ordering diverged", e)
	}
	action.Op = "smart-preview"
	response := coreVersionAction(home, mustEditorJSON(t, action))
	if !strings.Contains(response, `"smartPreview":[]`) {
		t.Fatal("template Smart preview rejected", response)
	}
}
func mustEditorJSON(t *testing.T, value any) string {
	t.Helper()
	b, e := json.Marshal(value)
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}
