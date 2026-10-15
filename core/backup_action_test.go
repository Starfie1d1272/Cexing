package main

import (
	"bytes"
	"context"
	"core/configpipeline"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const backupSource = "proxies: [{name: synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\nproxy-groups: [{name: Main, type: select, proxies: [synthetic]}]\nrules: [\"MATCH,Main\"]\n"

func backupPrefs() portableSettings {
	return portableSettings{KeepAlive: true, LogLevel: "info", MixedPort: 7890, AccessMode: "all", AccessList: []string{}, AutoUpdateIntervalHours: 24, AutoRestore: true, SmartAutoConvert: false}
}
func backupHome(t *testing.T) string {
	t.Helper()
	h := t.TempDir()
	if e := os.WriteFile(filepath.Join(h, "geoip.metadb"), []byte("synthetic"), 0600); e != nil {
		t.Fatal(e)
	}
	return h
}
func backupDo(t *testing.T, h string, a versionAction) *backupResponse {
	t.Helper()
	r, e := executeVersionAction(h, a)
	if e != nil {
		t.Fatal(a.Op, e)
	}
	if r.Backup == nil {
		t.Fatal("missing response")
	}
	return r.Backup
}
func backupFixture(t *testing.T, h string) *backupResponse {
	t.Helper()
	p := backupPrefs()
	prefs, _ := json.Marshal(p)
	m := backupManifest{SchemaVersion: 1, Preferences: p, GlobalMerge: "hosts: {example.invalid: 192.0.2.2}\n", Active: "one.yaml", Profiles: []backupProfile{{Name: "one.yaml", Original: backupSource, Overlay: "log-level: info\n", Metadata: json.RawMessage(`{"origin":"https://example.invalid/synthetic-token","sub":{"upload":0,"download":0,"total":0,"expire":0},"updatedAt":0}`), EditIntent: &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}}}}}
	if e := os.MkdirAll(filepath.Join(h, "backups"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := writeBackupJSON(filepath.Join(h, "backups", "backup-import-test.json"), m); e != nil {
		t.Fatal(e)
	}
	_ = prefs
	return backupDo(t, h, versionAction{Op: "backup-prepare", BackupFile: "backup-import-test.json"})
}
func backupArm(t *testing.T, h string, p *backupResponse) {
	t.Helper()
	prefs, _ := json.Marshal(backupPrefs())
	state, e := executeVersionAction(h, versionAction{Op: "read"})
	if e != nil {
		t.Fatal(e)
	}
	_ = state
	backupDo(t, h, versionAction{Op: "backup-arm", BackupToken: p.Token, BackupOwner: "synthetic-owner", BackupPreferences: prefs})
}
func TestBackupRoundTripConflictAndRecovery(t *testing.T) {
	h := backupHome(t)
	p := backupFixture(t, h)
	backupArm(t, h, p)
	r := backupDo(t, h, versionAction{Op: "backup-recover"})
	if r.Outcome != "prior" {
		t.Fatal(r)
	}
	backupDo(t, h, versionAction{Op: "backup-commit", BackupToken: p.Token})
	r = backupDo(t, h, versionAction{Op: "backup-recover"})
	if r.Outcome != "committed" || r.Preferences.MixedPort != 7890 {
		t.Fatal(r)
	}
	backupDo(t, h, versionAction{Op: "backup-ack", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
	store := configpipeline.FileStore{Root: filepath.Join(h, "profile-versions")}
	state, e := store.Load(context.Background())
	if e != nil || state.Current == nil {
		t.Fatal(e)
	}
	prefs, _ := json.Marshal(backupPrefs())
	export := backupDo(t, h, versionAction{Op: "backup-export", Expected: state.Current.ID, BackupPreferences: prefs})
	raw, e := os.ReadFile(filepath.Join(h, "backups", export.File))
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(raw, []byte("allowLan")) || bytes.Contains(raw, []byte("vpnWasConnected")) || bytes.Contains(raw, []byte("secret")) {
		t.Fatal("runtime safety data leaked")
	}
	var m backupManifest
	if decodeBackupJSON(raw, &m) != nil || len(m.Profiles) != 1 || m.Profiles[0].Original != backupSource || m.Profiles[0].EditIntent.Revision != "draft" {
		t.Fatal("lost provenance")
	}
	fresh := backupHome(t)
	if e = os.MkdirAll(filepath.Join(fresh, "backups"), 0700); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(fresh, "backups", "backup-import-test.json"), raw, 0600); e != nil {
		t.Fatal(e)
	}
	next := backupDo(t, fresh, versionAction{Op: "backup-prepare", BackupFile: "backup-import-test.json"})
	backupArm(t, fresh, next)
	backupDo(t, fresh, versionAction{Op: "backup-commit", BackupToken: next.Token})
	backupDo(t, fresh, versionAction{Op: "backup-ack", BackupToken: next.Token})
	backupDo(t, fresh, versionAction{Op: "backup-finish", BackupToken: next.Token})
	second := backupDo(t, h, versionAction{Op: "backup-prepare", Expected: state.Current.ID, BackupFile: export.File})
	if second.Names[0].To != "one (2).yaml" {
		t.Fatal("silently overwrote", second.Names)
	}
	before, _ := os.ReadFile(filepath.Join(h, "profile-versions", "state.json"))
	backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: second.Token})
	after, _ := os.ReadFile(filepath.Join(h, "profile-versions", "state.json"))
	if !bytes.Equal(before, after) {
		t.Fatal("cancel changed pointer")
	}
}
func TestBackupRejectsCorruptionAndPreservesSources(t *testing.T) {
	for _, mutate := range []func(*backupManifest){func(m *backupManifest) { m.SchemaVersion = 2 }, func(m *backupManifest) { m.Profiles[0].Name = "../evil.yaml" }, func(m *backupManifest) { m.Profiles = append(m.Profiles, m.Profiles[0]) }, func(m *backupManifest) { m.Active = "missing.yaml" }, func(m *backupManifest) { m.Preferences.MixedPort = 0 }, func(m *backupManifest) { m.Profiles[0].Original = "rules: [MATCH,Missing]" }} {
		h := backupHome(t)
		p := backupFixture(t, h)
		backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
		path := filepath.Join(h, "backups", "backup-import-test.json")
		raw, _ := os.ReadFile(path)
		var m backupManifest
		json.Unmarshal(raw, &m)
		mutate(&m)
		writeBackupJSON(path, m)
		if _, e := executeVersionAction(h, versionAction{Op: "backup-prepare", BackupFile: "backup-import-test.json"}); e == nil {
			t.Fatal("invalid backup accepted")
		}
		state, e := executeVersionAction(h, versionAction{Op: "read"})
		if e != nil || state.State.Current != nil {
			t.Fatal("invalid backup published")
		}
	}
	h := backupHome(t)
	p := backupFixture(t, h)
	backupArm(t, h, p)
	if report, e := executeVersionAction(h, versionAction{Op: "gc"}); e != nil || report.Storage == nil || report.Storage.Complete {
		t.Fatal("GC crossed restore journal")
	}
	// Simulate interruption before version publication: old preferences are selected.
	old := backupDo(t, h, versionAction{Op: "backup-recover"})
	if old.Outcome != "prior" {
		t.Fatal(old)
	}
	backupDo(t, h, versionAction{Op: "backup-ack", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
	p = backupFixture(t, h)
	raw, _ := os.ReadFile(filepath.Join(h, "backups", p.Token, "plan.json"))
	var plan backupPlan
	json.Unmarshal(raw, &plan)
	os.WriteFile(plan.Versions[0].Path, []byte("rules: [MATCH,Missing]"), 0600)
	prefs, _ := json.Marshal(backupPrefs())
	if _, e := executeVersionAction(h, versionAction{Op: "backup-arm", BackupToken: p.Token, BackupOwner: "test", BackupPreferences: prefs}); e == nil {
		t.Fatal("changed candidate accepted")
	}
	for _, bad := range []string{"{}", `{"schemaVersion":1,"controllerSecret":"private"}`, "{broken", strings.Repeat("x", maxBackupBytes+1)} {
		os.WriteFile(filepath.Join(h, "backups", "backup-import-bad.json"), []byte(bad), 0600)
		if _, e := executeVersionAction(h, versionAction{Op: "backup-prepare", BackupFile: "backup-import-bad.json"}); e == nil {
			t.Fatal("bad manifest accepted")
		}
	}
}
func TestBackupAbandonedPreviewAndSymlink(t *testing.T) {
	h := backupHome(t)
	p := backupFixture(t, h)
	backupDo(t, h, versionAction{Op: "backup-clean"})
	if fileExists(filepath.Join(h, "backups", p.Token)) {
		t.Fatal("preview not collected")
	}
	outside := filepath.Join(t.TempDir(), "private.json")
	os.WriteFile(outside, []byte("private"), 0600)
	path := filepath.Join(h, "backups", "backup-import-link.json")
	os.Symlink(outside, path)
	if _, e := executeVersionAction(h, versionAction{Op: "backup-prepare", BackupFile: filepath.Base(path)}); e == nil {
		t.Fatal("symlink accepted")
	}
	raw, _ := os.ReadFile(outside)
	if string(raw) != "private" {
		t.Fatal("outside touched")
	}
}

func TestBackupExportsRenamedPublishedAlias(t *testing.T) {
	h := backupHome(t)
	p := backupFixture(t, h)
	backupArm(t, h, p)
	backupDo(t, h, versionAction{Op: "backup-commit", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-ack", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
	state, e := executeVersionAction(h, versionAction{Op: "read"})
	if e != nil {
		t.Fatal(e)
	}
	id := state.State.Current.ID
	if _, e = executeVersionAction(h, versionAction{Op: "rename", Expected: id, ProfileID: "one.yaml", NewProfileID: "renamed.yaml"}); e != nil {
		t.Fatal(e)
	}
	prefs, _ := json.Marshal(backupPrefs())
	export := backupDo(t, h, versionAction{Op: "backup-export", Expected: id, BackupPreferences: prefs})
	raw, e := os.ReadFile(filepath.Join(h, "backups", export.File))
	var m backupManifest
	if e != nil || decodeBackupJSON(raw, &m) != nil || m.Active != "renamed.yaml" || m.Profiles[0].Name != "renamed.yaml" || m.Profiles[0].Original != backupSource {
		t.Fatal("renamed alias lost", e)
	}
}

func TestBackupBindsPreviewBytesAtArmAndCommit(t *testing.T) {
	for _, phase := range []string{"arm", "commit"} {
		for _, name := range []string{"config.yaml", "original.yaml", "source.json", "overlay.yaml"} {
			t.Run(phase+"/"+name, func(t *testing.T) {
				h := backupHome(t)
				p := backupFixture(t, h)
				if phase == "commit" {
					backupArm(t, h, p)
				}
				root, e := backupRoot(h)
				if e != nil {
					t.Fatal(e)
				}
				plan, e := loadBackupPlan(root, p.Token)
				root.Close()
				if e != nil {
					t.Fatal(e)
				}
				path := filepath.Join(filepath.Dir(plan.Versions[0].Path), name)
				raw, e := os.ReadFile(path)
				if e != nil {
					t.Fatal(e)
				}
				if name == "source.json" {
					var source map[string]any
					json.Unmarshal(raw, &source)
					source["Metadata"] = `{"origin":"changed"}`
					raw, _ = json.Marshal(source)
				} else {
					raw = append(raw, []byte("\nx-approved: false\n")...)
				}
				if e = os.WriteFile(path, raw, 0600); e != nil {
					t.Fatal(e)
				}
				a := versionAction{Op: "backup-commit", BackupToken: p.Token}
				if phase == "arm" {
					prefs, _ := json.Marshal(backupPrefs())
					a = versionAction{Op: "backup-arm", BackupToken: p.Token, BackupOwner: "test", BackupPreferences: prefs}
				}
				if _, e = executeVersionAction(h, a); e == nil || e.Error() != "BACKUP_VERIFY_FAILED" {
					t.Fatal("changed but valid candidate accepted", e)
				}
				state, e := executeVersionAction(h, versionAction{Op: "read"})
				if e != nil || state.State.Current != nil {
					t.Fatal("changed candidate published", e)
				}
			})
		}
	}
}
func TestEmptyBackupRestoresPreferencesOnFirstAttempt(t *testing.T) {
	for _, existing := range []bool{false, true} {
		t.Run(fmt.Sprint(existing), func(t *testing.T) {
			h := backupHome(t)
			if existing {
				store := configpipeline.FileStore{Root: filepath.Join(h, "profile-versions")}
				os.MkdirAll(store.Root, 0700)
				if e := store.Publish(context.Background(), configpipeline.Snapshot{Profiles: map[string]configpipeline.Version{}}); e != nil {
					t.Fatal(e)
				}
			}
			prefs := backupPrefs()
			prefs.MixedPort = 9125
			m := backupManifest{SchemaVersion: 1, Preferences: prefs, Profiles: []backupProfile{}}
			os.MkdirAll(filepath.Join(h, "backups"), 0700)
			if e := writeBackupJSON(filepath.Join(h, "backups", "backup-import-empty.json"), m); e != nil {
				t.Fatal(e)
			}
			p := backupDo(t, h, versionAction{Op: "backup-prepare", BackupFile: "backup-import-empty.json"})
			if p.Profiles != 0 {
				t.Fatal("empty preview shape")
			}
			backupArm(t, h, p)
			before := backupDo(t, h, versionAction{Op: "backup-recover"})
			if before.Outcome != "prior" || before.Preferences.MixedPort != 7890 {
				t.Fatal("armed is not committed", before)
			}
			backupDo(t, h, versionAction{Op: "backup-commit", BackupToken: p.Token})
			status := backupDo(t, h, versionAction{Op: "backup-status", BackupToken: p.Token})
			if status.Outcome != "committed" {
				t.Fatal(status)
			}
			after := backupDo(t, h, versionAction{Op: "backup-recover"})
			if after.Outcome != "committed" || after.Preferences.MixedPort != 9125 {
				t.Fatal(after)
			}
			backupDo(t, h, versionAction{Op: "backup-ack", BackupToken: p.Token})
			backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
			if p.Names == nil {
				t.Fatal("empty preview must serialize names as an array")
			}
		})
	}
}

func TestBackupJournalFencesOtherPublications(t *testing.T) {
	h := backupHome(t)
	p := backupFixture(t, h)
	backupArm(t, h, p)
	for _, op := range []string{"stage", "commit", "rename", "remove", "backup-prepare", "backup-export"} {
		if _, e := executeVersionAction(h, versionAction{Op: op}); e == nil || e.Error() != "BACKUP_RECOVERY_REQUIRED" {
			t.Fatal(op, "crossed journal fence", e)
		}
	}
	if r, e := executeVersionAction(h, versionAction{Op: "read"}); e != nil || r.State.Current != nil {
		t.Fatal("read blocked or pointer changed", e)
	}
}

func TestBackupAcceptsRegionProvenanceWithoutExportingRuntimeChoices(t *testing.T) {
	h := backupHome(t)
	p := backupFixture(t, h)
	backupArm(t, h, p)
	backupDo(t, h, versionAction{Op: "backup-commit", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-ack", BackupToken: p.Token})
	backupDo(t, h, versionAction{Op: "backup-finish", BackupToken: p.Token})
	state, e := executeVersionAction(h, versionAction{Op: "read"})
	if e != nil {
		t.Fatal(e)
	}
	observed := "synthetic-runtime-observed"
	stage, e := executeVersionAction(h, versionAction{Op: "stage", Expected: state.State.Current.ID, ProfileID: "one.yaml", Original: backupSource, Metadata: "{}", Overrides: `{"mixedPort":7890}`, RegionChoice: &configpipeline.RegionChoice{Pending: "Main", Previous: &configpipeline.RegionPreviousChoice{Selector: "Old", Name: "synthetic-runtime-manual", Observed: &observed}}})
	if e != nil {
		t.Fatal(e)
	}
	_, e = executeVersionAction(h, versionAction{Op: "commit", Expected: state.State.Current.ID, VersionID: stage.Version.ID, Active: true})
	if e != nil {
		t.Fatal(e)
	}
	prefs, _ := json.Marshal(backupPrefs())
	exported := backupDo(t, h, versionAction{Op: "backup-export", Expected: stage.Version.ID, BackupPreferences: prefs})
	raw, e := os.ReadFile(filepath.Join(h, "backups", exported.File))
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(raw, []byte("synthetic-runtime")) || bytes.Contains(raw, []byte("regionChoice")) {
		t.Fatal("export leaked runtime choice")
	}
	restored := backupDo(t, h, versionAction{Op: "backup-prepare", Expected: stage.Version.ID, BackupFile: exported.File})
	root, e := os.OpenRoot(filepath.Join(h, "backups"))
	if e != nil {
		t.Fatal(e)
	}
	defer root.Close()
	plan, e := loadBackupPlan(root, restored.Token)
	if e != nil {
		t.Fatal(e)
	}
	source, e := os.ReadFile(filepath.Join(h, "profile-versions", plan.Versions[0].ID, "source.json"))
	if e != nil {
		t.Fatal(e)
	}
	var provenance struct{ RegionChoice *configpipeline.RegionChoice }
	if json.Unmarshal(source, &provenance) != nil || provenance.RegionChoice == nil || provenance.RegionChoice.Previous != nil || provenance.RegionChoice.Pending != "" {
		t.Fatal("restore replayed runtime choice")
	}
}
