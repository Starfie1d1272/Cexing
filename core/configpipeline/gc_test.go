package configpipeline

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func gcFixture(t *testing.T, n int) (FileStore, Snapshot, []Version) {
	t.Helper()
	s := FileStore{Root: filepath.Join(t.TempDir(), "profile-versions")}
	state := Snapshot{Profiles: map[string]Version{}}
	var history []Version
	for i := 0; i < n; i++ {
		original := []byte("proxies: []\nrules: ['MATCH,DIRECT']\n")
		digest := sha256.Sum256(original)
		v, err := s.Stage(context.Background(), Result{Original: original, YAML: original, Digest: hex.EncodeToString(digest[:]), ProfileID: "a.yaml", Metadata: "{}"})
		if err != nil {
			t.Fatal(err)
		}
		state.Previous = state.Current
		state.Current = &v
		state.Profiles["a.yaml"] = v
		if err = s.Publish(context.Background(), state); err != nil {
			t.Fatal(err)
		}
		history = append(history, v)
	}
	return s, state, history
}
func TestCollectKeepsReachabilityAndExtraPinsAcross120Publications(t *testing.T) {
	s, state, history := gcFixture(t, 120)
	b := history[3]
	b.ProfileID = "b.yaml"
	state.Profiles["b.yaml"] = b
	if err := s.Publish(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	usage, err := s.Collect(context.Background(), state, []Version{history[0]})
	if err != nil {
		t.Fatal(err)
	}
	if usage.Versions != 4 || usage.RemovedVersions != 116 || usage.Bytes <= 0 || usage.RemovedBytes <= 0 {
		t.Fatal(usage)
	}
	for _, v := range []Version{*state.Current, *state.Previous, b, history[0]} {
		if _, err := os.Stat(v.Path); err != nil {
			t.Fatal("reachable removed", err)
		}
	}
	if _, err = os.Stat(history[1].Path); !os.IsNotExist(err) {
		t.Fatal("garbage retained", err)
	}
	if _, err = s.Load(context.Background()); err != nil {
		t.Fatal("remaining pointer invalid", err)
	}
}
func TestCollectBlocksReadersCandidatesUnknownAndUnexpectedFiles(t *testing.T) {
	s, state, history := gcFixture(t, 4)
	release, err := s.AcquireReadLease()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("reader ignored")
	}
	release()
	original := []byte("proxies: []\n")
	digest := sha256.Sum256(original)
	pending, err := s.Stage(context.Background(), Result{Original: original, YAML: original, Digest: hex.EncodeToString(digest[:]), ProfileID: "c.yaml", Metadata: "{}"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("candidate ignored")
	}
	if err = s.Discard(context.Background(), pending); err != nil {
		t.Fatal(err)
	}
	profiles := filepath.Join(filepath.Dir(s.Root), "profiles")
	if err = os.MkdirAll(profiles, 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(profiles, "apply-uncertain.txt")
	if err = os.WriteFile(marker, []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("unknown ignored")
	}
	os.Remove(marker)
	unknown := filepath.Join(s.Root, history[0].ID, "unknown-user-file")
	if err = os.WriteFile(unknown, []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("unknown file ignored")
	}
	if b, err := os.ReadFile(unknown); err != nil || string(b) != "preserve" {
		t.Fatal("unknown data removed", err)
	}
	for _, v := range history {
		if _, err = os.Stat(v.Path); err != nil {
			t.Fatal("fail closed collection removed another candidate", err)
		}
	}
}
func TestCollectRejectsSymlinksBadStateAndResumesQuarantine(t *testing.T) {
	s, state, history := gcFixture(t, 5)
	outside := t.TempDir()
	marker := filepath.Join(outside, "keep")
	os.WriteFile(marker, []byte("safe"), 0600)
	link := filepath.Join(s.Root, "version-link")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("symlink ignored")
	}
	os.Remove(link)
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("outside touched", err)
	}
	statePath := filepath.Join(s.Root, "state.json")
	raw, _ := os.ReadFile(statePath)
	var future map[string]any
	json.Unmarshal(raw, &future)
	future["UnknownFutureRefs"] = []string{history[0].ID}
	changed, _ := json.Marshal(future)
	os.WriteFile(statePath, changed, 0600)
	if _, err := s.Collect(context.Background(), state, nil); err == nil {
		t.Fatal("future references ignored")
	}
	os.WriteFile(statePath, raw, 0600)
	quarantine := filepath.Join(s.Root, ".gc-"+history[0].ID)
	if err := os.Rename(filepath.Dir(history[0].Path), quarantine); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(quarantine, "config.yaml")) // interrupted removal; source remains until last
	if _, err := s.Collect(context.Background(), state, nil); err != nil {
		t.Fatal("quarantine did not resume", err)
	}
	if _, err := os.Stat(quarantine); !os.IsNotExist(err) {
		t.Fatal("quarantine remained", err)
	}
	if _, err := os.Stat(state.Current.Path); err != nil {
		t.Fatal("current removed", err)
	}
}
