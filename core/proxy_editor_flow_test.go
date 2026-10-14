package main

import (
	"bytes"
	"core/configpipeline"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The native form emitter feeds the real worker preview/stage/verify/commit
// path. This is a disconnected synthetic publication, never a VPN start.
func TestNativeProxyFormPublishesThroughWorker(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := `proxies:
  - {name: original-node, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: synthetic-password, x-advanced: {keep: true}}
proxy-providers:
  source: {type: inline, payload: [{name: from-provider, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: synthetic-password}]}
proxy-groups:
  - {name: main, type: url-test, proxies: [original-node], use: [source], url: 'https://example.invalid/check', interval: 300}
rules: ['MATCH,main']
`
	view, err := executeVersionAction(home, versionAction{Op: "editor-list", Original: original})
	if err != nil || view.Editable == nil {
		t.Fatal("editor list", err)
	}
	targets := map[string]*configpipeline.EditTarget{}
	for _, section := range view.Editable.Sections {
		if section.Section != "proxies" && section.Section != "proxy-providers" {
			continue
		}
		read, err := executeVersionAction(home, versionAction{Op: "edit-target", Original: original,
			EditSection: section.Section, EditTarget: section.Items[0].ID})
		if err != nil || read.EditTarget == nil {
			t.Fatal("target", err)
		}
		targets[section.Section] = read.EditTarget
	}
	input, _ := json.Marshal(map[string]any{"sourceRevision": view.Editable.SourceRevision,
		"node": targets["proxies"], "provider": targets["proxy-providers"],
		"missing": view.Editable.MissingFieldRevision, "rename": true})
	command := exec.Command("node", "scripts/emit-proxy-form-fixture.cjs")
	command.Dir = ".."
	command.Stdin = bytes.NewReader(input)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("native form: %v\n%s", err, output)
	}
	intent, err := configpipeline.DecodeEditIntent(output)
	if err != nil {
		t.Fatal(err)
	}
	intent.Template = &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "main"}
	action := versionAction{Op: "edit-preview", Original: original, EditIntent: intent, SmartConversion: true}
	preview, err := executeVersionAction(home, action)
	if err != nil || preview.MergePreview == nil {
		t.Fatal("preview", err, preview.Error)
	}
	action.Op = "stage"
	action.ProfileID = "synthetic.yaml"
	action.Metadata = `{}`
	staged, err := executeVersionAction(home, action)
	if err != nil || staged.Version == nil || staged.Digest != preview.MergePreview.Digest {
		t.Fatal("stage must reproduce confirmed preview", err, staged.Error)
	}
	verified, err := executeVersionAction(home, versionAction{Op: "verify", VersionID: staged.Version.ID})
	if err != nil || verified.Receipt != staged.Receipt || staged.Receipt == "" {
		t.Fatal("verify", err)
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: staged.Version.ID,
		ProfileID: action.ProfileID, Active: true}); err != nil {
		t.Fatal("commit", err)
	}
	content, err := os.ReadFile(staged.Version.Path)
	if err != nil || !strings.Contains(string(content), "renamed-node") ||
		!strings.Contains(string(content), "8443") || !strings.Contains(string(content), "chatgpt.com") ||
		!strings.Contains(string(content), "type: smart") {
		t.Fatal("published form/template/Smart output", err)
	}
	dir := filepath.Dir(staged.Version.Path)
	if source, err := os.ReadFile(filepath.Join(dir, "original.yaml")); err != nil || string(source) != original {
		t.Fatal("original must remain intact", err)
	}
	var source struct{ EditIntent *configpipeline.EditIntent }
	provenance, _ := os.ReadFile(filepath.Join(dir, "source.json"))
	if err := json.Unmarshal(provenance, &source); err != nil || source.EditIntent == nil || source.EditIntent.Template == nil {
		t.Fatal("combined provenance", err)
	}
	action.Expected = staged.Version.ID
	action.Original = strings.Replace(original, "port: 443", "port: 2080", 1)
	rejected, err := executeVersionAction(home, action)
	if err == nil && (rejected.EditError == nil || rejected.EditError.Code != "conflict") {
		t.Fatal("source conflict accepted")
	}
	state, err := executeVersionAction(home, versionAction{Op: "read"})
	if err != nil || state.State.Current.ID != staged.Version.ID {
		t.Fatal("failed update moved successful pointer", err)
	}
}
