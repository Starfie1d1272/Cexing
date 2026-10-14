package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEditorBridgeIsReadOnlyPrivateAndRevisionChecked(t *testing.T) {
	home := t.TempDir()
	source, err := os.ReadFile("configpipeline/testdata/edit-source.yaml")
	if err != nil {
		t.Fatal(err)
	}
	action := versionAction{Op: "edit-read", Original: string(source)}
	response, err := executeVersionAction(home, action)
	if err != nil || response.Editable == nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(response)
	for _, secret := range []string{"node-a", "private.test", "resolver.test", "public.test"} {
		if strings.Contains(string(b), secret) {
			t.Fatal("summary leak", secret)
		}
	}
	action.Op = "edit-target"
	action.EditSection = "proxies"
	action.EditTarget = response.Editable.Sections[0].Items[0].ID
	response, err = executeVersionAction(home, action)
	if err != nil || response.EditTarget == nil || !strings.Contains(string(response.EditTarget.Value), "node-a") {
		t.Fatal("explicit target missing", err)
	}
	action.Expected = "old-version"
	if _, err = executeVersionAction(home, action); err == nil || err.Error() != "VERSION_STALE" {
		t.Fatal("stale request accepted", err)
	}
	if _, err = os.Stat(filepath.Join(home, "profile-versions")); !os.IsNotExist(err) {
		t.Fatal("editor read wrote versions", err)
	}
}

func TestSmartPreviewReturnsEmptySuccessAndStrictIntentSchema(t *testing.T) {
	home := t.TempDir()
	input := `{"op":"smart-preview","original":"proxies: [{name: a, type: direct}]\n","smartConversion":true}`
	result := coreVersionAction(home, input)
	if !strings.Contains(result, `"smartPreview":[]`) || strings.Contains(result, `"error"`) {
		t.Fatal("no eligible groups reported as failure", result)
	}
	input = `{"op":"smart-preview","original":"proxies: [{name: a, type: direct}]\n","editIntent":{"schemaVersion":1,"revision":"d","sourceRevision":"s","operations":[],"private-unknown":"secret"}}`
	result = coreVersionAction(home, input)
	if !strings.Contains(result, `"code":"invalid_schema"`) || strings.Contains(result, "secret") || strings.Contains(result, "private-unknown") {
		t.Fatal("schema boundary leak", result)
	}
}
