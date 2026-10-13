package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVersionActionSmartTogglePreservesOriginal(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := "proxies: [{name: node, type: socks5, server: 192.0.2.1, port: 1080}]\n" +
		"proxy-groups: [{name: automatic, type: url-test, proxies: [node]}, {name: manual, type: select, proxies: [automatic, DIRECT]}]\n" +
		"rules: ['MATCH,manual']\n"
	act := versionAction{Op: "stage", ProfileID: "source.yaml", Original: original, Metadata: `{}`, SmartConversion: true}
	on, err := executeVersionAction(home, act)
	if err != nil || on.Version == nil {
		t.Fatalf("enabled stage: %v", err)
	}
	generated, err := os.ReadFile(on.Version.Path)
	if err != nil || !strings.Contains(string(generated), "type: smart") ||
		!strings.Contains(string(generated), "type: select") || !strings.Contains(string(generated), "MATCH,manual") {
		t.Fatal("enabled generated policy lost group or rule")
	}
	stored, err := os.ReadFile(filepath.Join(filepath.Dir(on.Version.Path), "original.yaml"))
	if err != nil || string(stored) != original {
		t.Fatal("subscription source changed")
	}
	source, err := os.ReadFile(filepath.Join(filepath.Dir(on.Version.Path), "source.json"))
	if err != nil || !strings.Contains(string(source), `"SmartConversion":true`) {
		t.Fatal("enabled policy provenance missing")
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: on.Version.ID, Active: true}); err != nil {
		t.Fatal(err)
	}
	act.Expected = on.Version.ID
	act.SmartConversion = false
	off, err := executeVersionAction(home, act)
	if err != nil || off.Version == nil {
		t.Fatalf("disabled stage: %v", err)
	}
	generated, err = os.ReadFile(off.Version.Path)
	if err != nil || !strings.Contains(string(generated), "type: url-test") || strings.Contains(string(generated), "type: smart") {
		t.Fatal("disabled version did not restore original group type")
	}
}

func TestVersionActionPublishesPerProfileAndKeepsPrevious(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	base := "proxies: [{name: node, type: socks5, server: 192.0.2.1, port: 1080}]\nproxy-groups: [{name: pick, type: select, proxies: [node]}]\nrules: ['MATCH,pick']\n"
	act := versionAction{Op: "stage", ProfileID: "one.yaml", Original: base, Metadata: `{}`}
	staged, err := executeVersionAction(home, act)
	if err != nil || staged.Version == nil {
		t.Fatalf("stage: %v", err)
	}
	state, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: staged.Version.ID, Active: true})
	if err != nil || state.State.Current.ID != staged.Version.ID {
		t.Fatalf("commit: %v", err)
	}
	if got, _ := os.ReadFile(state.State.Current.Path); len(got) == 0 {
		t.Fatal("empty generated config")
	}
	act.ProfileID = "two.yaml"
	act.Expected = staged.Version.ID
	act.Overlay = "hosts: {example.invalid: 192.0.2.3}\n"
	second, err := executeVersionAction(home, act)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: second.Version.ID, Expected: staged.Version.ID}); err != nil {
		t.Fatal(err)
	}
	read, err := executeVersionAction(home, versionAction{Op: "read"})
	if err != nil || read.State.Current.ID != staged.Version.ID || read.State.Profiles["two.yaml"].ID != second.Version.ID {
		t.Fatal("inactive edit changed active pointer or lost profile version")
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: second.Version.ID, Active: true}); err == nil {
		t.Fatal("stale update accepted")
	}
	third, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: second.Version.ID, Expected: staged.Version.ID, Active: true})
	if err != nil || third.State.Previous.ID != staged.Version.ID {
		t.Fatalf("switch: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(home, "profile-versions", "state.json"))
	if err != nil || !json.Valid(data) {
		t.Fatal("atomic state missing")
	}
	renamed, err := executeVersionAction(home, versionAction{Op: "rename", ProfileID: "two.yaml",
		NewProfileID: "renamed.yaml", Expected: second.Version.ID})
	if err != nil || renamed.State.Current.ProfileID != "renamed.yaml" ||
		renamed.State.Profiles["renamed.yaml"].ID != second.Version.ID {
		t.Fatalf("rename: %v", err)
	}
	removed, err := executeVersionAction(home, versionAction{Op: "remove", ProfileID: "renamed.yaml",
		Expected: second.Version.ID})
	if err != nil || removed.State.Current != nil || removed.State.Profiles["renamed.yaml"].ID != "" {
		t.Fatalf("remove: %v", err)
	}
	restarted, err := executeVersionAction(home, versionAction{Op: "read"})
	if err != nil || restarted.State.Current != nil || restarted.State.Profiles["one.yaml"].ID != staged.Version.ID {
		t.Fatal("restart state lost prior profile")
	}
	restored, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: second.Version.ID,
		ProfileID: "renamed.yaml", Active: true})
	if err != nil || restored.State.Current.ProfileID != "renamed.yaml" ||
		restored.State.Profiles["renamed.yaml"].ID != second.Version.ID {
		t.Fatalf("rename deletion rollback: %v", err)
	}
	if err := os.Remove(filepath.Join(home, "profile-versions", second.Version.ID, "source.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := executeVersionAction(home, versionAction{Op: "read"}); err == nil {
		t.Fatal("missing provenance accepted after restart")
	}
}

func TestVersionActionAcceptsExistingUppercaseYAMLExtension(t *testing.T) {
	if !profileIDPattern.MatchString("Imported.YAML") || !profileIDPattern.MatchString("Imported.YML") {
		t.Fatal("existing import extension rejected")
	}
}
