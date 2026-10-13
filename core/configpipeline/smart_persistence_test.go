package configpipeline

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

// Exercise the selected private version across a Smart toggle, a subscription
// update, and a fresh store instance (the host's restart read path).
func TestSmartToggleUpdateSurvivesStoreReload(t *testing.T) {
	const first = "proxies: [{name: a, type: direct}, {name: b, type: direct}]\n" +
		"proxy-groups: [{name: auto, type: url-test, proxies: [a, b]}, {name: balance, type: load-balance, proxies: [a, b]}, {name: manual, type: select, proxies: [auto, balance, DIRECT]}]\n" +
		"rules: ['MATCH,manual']\n"
	const updated = "# updated subscription; keep these exact bytes\n" +
		"proxies: [{name: a, type: direct}, {name: b, type: direct}]\n" +
		"proxy-groups: [{name: auto, type: url-test, proxies: [b, a]}, {name: balance, type: load-balance, proxies: [b, a]}, {name: manual, type: select, proxies: [auto, balance, DIRECT]}]\n" +
		"rules: ['MATCH,manual']\n"

	ctx := context.Background()
	root := filepath.Join(t.TempDir(), "private")
	store := FileStore{Root: root}
	tx := Transaction{Compiler: compiler(), Store: store, Activator: &fakeCore{}}
	for _, step := range []struct {
		name, original string
		smart          bool
	}{
		{"enabled", first, true},
		{"disabled", first, false},
		{"re-enabled", first, true},
		{"updated", updated, true},
	} {
		t.Run(step.name, func(t *testing.T) {
			before, err := store.Load(ctx)
			if err != nil {
				t.Fatal(err)
			}
			req := Request{Original: []byte(step.original)}
			if before.Current != nil {
				req.ExpectedActiveRevision = before.Current.ID
			}
			if step.smart {
				req.Strategy = SmartAuto
			}
			if _, err := tx.Apply(ctx, req); err != nil {
				t.Fatal(err)
			}
			// Open the committed pointer with a new store instance, as after a
			// host restart, rather than inspecting only the compiler result.
			reloaded, err := (FileStore{Root: root}).Load(ctx)
			if err != nil || reloaded.Current == nil {
				t.Fatalf("selected version did not reload: %v", err)
			}
			versionDir := filepath.Dir(reloaded.Current.Path)
			raw, err := os.ReadFile(filepath.Join(versionDir, "original.yaml"))
			if err != nil || !bytes.Equal(raw, []byte(step.original)) {
				t.Fatalf("original subscription bytes changed: %v", err)
			}
			generated, err := os.ReadFile(reloaded.Current.Path)
			if err != nil {
				t.Fatal(err)
			}
			var doc struct {
				Groups []struct {
					Name string `yaml:"name"`
					Type string `yaml:"type"`
				} `yaml:"proxy-groups"`
			}
			if err := yaml.Unmarshal(generated, &doc); err != nil || len(doc.Groups) != 3 {
				t.Fatalf("invalid selected config: %v", err)
			}
			want := "smart"
			if !step.smart {
				want = "url-test"
			}
			balance := "smart"
			if !step.smart {
				balance = "load-balance"
			}
			if doc.Groups[0].Name != "auto" || doc.Groups[0].Type != want ||
				doc.Groups[1].Name != "balance" || doc.Groups[1].Type != balance ||
				doc.Groups[2].Name != "manual" || doc.Groups[2].Type != "select" {
				t.Fatalf("unexpected group types after reload: %+v", doc.Groups)
			}
		})
	}
}
