package main

import (
	"core/configpipeline"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIntentStagingProvenanceAndUpdateConflicts(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := `proxies:
  - {name: synthetic, type: socks5, server: 192.0.2.1, port: 1080, udp: true}
proxy-groups:
  - {name: Main, type: select, proxies: [synthetic]}
rules: ["MATCH,Main"]
`
	view, err := configpipeline.ReadEditable([]byte(original), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	id := view.Sections[0].Items[0].ID
	target, err := configpipeline.ReadEditTarget([]byte(original), nil, nil, "proxies", id)
	if err != nil {
		t.Fatal(err)
	}
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "private-draft", SourceRevision: view.SourceRevision, Operations: []configpipeline.EditOperation{{ID: "port", Kind: "update", Section: "proxies", Target: id, Preconditions: map[string]string{"port": target.Item.Fields["port"]}, Patch: json.RawMessage(`{"port":1081}`)}}}
	action := versionAction{Op: "stage", ProfileID: "synthetic.yaml", Original: original, Metadata: `{}`, EditIntent: intent}
	staged, err := executeVersionAction(home, action)
	if err != nil {
		t.Fatal(err)
	}
	generated, err := os.ReadFile(staged.Version.Path)
	if err != nil || !strings.Contains(string(generated), "1081") {
		t.Fatal("intent not compiled", err)
	}
	var provenance struct{ EditIntent *configpipeline.EditIntent }
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "source.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &provenance); err != nil || provenance.EditIntent == nil || provenance.EditIntent.Revision != intent.Revision {
		t.Fatal("provenance missing", err)
	}
	raw, _ = os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "original.yaml"))
	if string(raw) != original {
		t.Fatal("original rewritten")
	}
	if _, err = executeVersionAction(home, versionAction{Op: "commit", VersionID: staged.Version.ID, ProfileID: action.ProfileID, Active: true}); err != nil {
		t.Fatal(err)
	}
	action.Expected = staged.Version.ID
	action.Original = strings.Replace(original, "udp: true", "udp: false", 1)
	if _, err = executeVersionAction(home, action); err != nil {
		t.Fatal("unrelated source update must rebase", err)
	}
	action.Original = strings.Replace(original, "port: 1080", "port: 2080", 1)
	if rejected, failure := executeVersionAction(home, action); failure == nil && (rejected.EditError == nil || rejected.EditError.Code != "conflict") {
