package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"core/configpipeline"
	"gopkg.in/yaml.v3"
)

// Isolate the locked parser/Smart singleton from the rest of the host suite.
// No TUN, controller, provider fetch or listener activation is requested.
func TestRegionResourceProjectionUsesEffectiveProviderAndDefersGeneratedEdits(t *testing.T) {
	if os.Getenv("CEXING_REGION_RESOURCE_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestRegionResourceProjectionUsesEffectiveProviderAndDefersGeneratedEdits$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_REGION_RESOURCE_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("region resource child: %v\n%s", err, out)
		}
		return
	}
	home := t.TempDir()
	if err := initControllerSecurity(home); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, "providers"), 0700); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"geoip.metadb":       "synthetic",
		"providers/old.yaml": "proxies: [{name: HK-old, type: direct}, {name: JP-old, type: direct}]\n",
		"providers/new.yaml": "proxies: [{name: SG-new, type: direct}, {name: US-new, type: direct}]\n",
	} {
		if err := os.WriteFile(filepath.Join(home, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	source := "proxy-providers: {feed: {type: file, path: providers/old.yaml, x-unknown: retained}}\nproxy-groups: [{name: Main, type: select, use: [feed]}]\nrules: ['MATCH,Main']\ndns: {enable: false}\nx-source: unchanged\n"
	original, err := configpipeline.ReadEditable([]byte(source), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := configpipeline.ReadEditTarget([]byte(source), nil, nil, "proxy-providers", original.Sections[1].Items[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	call := func(action versionAction) versionResponse {
		t.Helper()
		data, _ := json.Marshal(action)
		raw := coreVersionAction(home, string(data))
		var response versionResponse
		if err := json.Unmarshal([]byte(raw), &response); err != nil || response.Error != "" {
			t.Fatal("worker rejected projection", action.Op, response.Error, response.EditError, err)
		}
		return response
	}
	for _, scenario := range []struct {
		name                              string
		path, rename, generated, template bool
	}{
		{name: "path", path: true}, {name: "rename", rename: true},
		{name: "path-rename-generated", path: true, rename: true, generated: true},
		{name: "template-path-rename-generated", path: true, rename: true, generated: true, template: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: original.SourceRevision, Operations: []configpipeline.EditOperation{}}
			plan := &configpipeline.RegionPlan{Mode: "region", Enable: true, Selector: "Main"}
			if scenario.template {
				intent.Template = &configpipeline.TemplatePlan{TemplateID: "region", Version: 1, Region: plan}
			}
			if scenario.path {
				intent.Operations = append(intent.Operations, configpipeline.EditOperation{ID: "provider-path", Kind: "update", Section: "proxy-providers", Target: provider.Item.ID, Preconditions: map[string]string{"path": provider.Item.Fields["path"]}, Patch: json.RawMessage(`{"path":"providers/new.yaml"}`)})
			}
			if scenario.rename {
				intent.Operations = append(intent.Operations, configpipeline.EditOperation{ID: "provider-rename", Kind: "rename", Section: "proxy-providers", Target: provider.Item.ID, Expected: provider.Item.Revision, Name: "renamed"})
			}
			action := versionAction{Op: "editor-list", Original: source, EditIntent: intent, RegionPlan: plan}
			if _, err := editorReadRequest(home, action, ""); err != nil {
				t.Fatal("resource request", err)
			}
			view := call(action)
			if view.Editable == nil {
				t.Fatal("no authoring projection")
			}
			if scenario.generated {
				var group configpipeline.EditableItem
				for _, section := range view.Editable.Sections {
					if section.Section == "proxy-groups" {
						for _, item := range section.Items {
							if strings.Contains(item.Name, "新加坡") {
								group = item
							}
						}
					}
				}
				if group.ID == "" {
					t.Fatal("updated provider region not generated")
				}
				action.Op = "edit-target"
				action.EditSection = "proxy-groups"
				action.EditTarget = group.ID
				target := call(action)
				if target.EditTarget == nil {
					t.Fatal("generated target absent")
				}
				intent.Operations = append(intent.Operations, configpipeline.EditOperation{ID: "generated-edit", Kind: "update", Section: "proxy-groups", Target: group.ID, Preconditions: map[string]string{"x-personal": target.EditTarget.MissingFieldRevision}, Patch: json.RawMessage(`{"x-personal":true}`)})
			}
			if scenario.generated {
				// Provider rename has already rewritten Main.use by phase two;
				// its original whole-target guard must remain available.
				main := original.Sections[2].Items[0]
				intent.Operations = append(intent.Operations, configpipeline.EditOperation{ID: "source-group-rename", Kind: "rename", Section: "proxy-groups", Target: main.ID, Expected: main.Revision, Name: "Personal Main"})
			}
			before, _ := json.Marshal(intent)
			action.Op = "stage"
			action.ProfileID = scenario.name + ".yaml"
			action.Metadata = `{}`
			staged := call(action)
			if staged.Version == nil {
				t.Fatal("no validated stage")
			}
			output, err := os.ReadFile(staged.Version.Path)
			if err != nil {
				t.Fatal(err)
			}
			if scenario.path && (!strings.Contains(string(output), "SG-new") || !strings.Contains(string(output), "US-new") || strings.Contains(string(output), "HK-old") || strings.Contains(string(output), "JP-old")) {
				t.Fatal("stale provider members leaked into generated filters")
			}
			if scenario.rename {
				var candidate struct {
					Providers map[string]any `yaml:"proxy-providers"`
					Groups    []struct {
						Use []string `yaml:"use"`
					} `yaml:"proxy-groups"`
				}
				if err := yaml.Unmarshal(output, &candidate); err != nil {
					t.Fatal(err)
				}
				if candidate.Providers["renamed"] == nil || candidate.Providers["feed"] != nil {
					t.Fatal("provider rename lost")
				}
				seen := false
				for _, g := range candidate.Groups {
					for _, name := range g.Use {
						if name == "feed" {
							t.Fatal("stale provider reference")
						}
						if name == "renamed" {
							seen = true
						}
					}
				}
				if !seen {
					t.Fatal("renamed provider reference missing")
				}
			}
			if scenario.generated && !strings.Contains(string(output), "x-personal: true") {
				t.Fatal("generated group edit lost")
			}
			if !strings.Contains(string(output), "x-unknown: retained") || !strings.Contains(string(output), "x-source: unchanged") {
				t.Fatal("unknown source fields lost")
			}
			after, _ := json.Marshal(intent)
			if string(before) != string(after) {
				t.Fatal("projection mutated intent")
			}
			stored, err := os.ReadFile(filepath.Join(filepath.Dir(staged.Version.Path), "original.yaml"))
			if err != nil || string(stored) != source {
				t.Fatal("original modified", err)
			}
			// Strict stale guards still reject a real upstream provider path change.
			if scenario.path {
				stale := action
				stale.Original = strings.Replace(source, "providers/old.yaml", "providers/new.yaml", 1)
				encoded, _ := json.Marshal(stale)
				var rejected versionResponse
				if json.Unmarshal([]byte(coreVersionAction(home, string(encoded))), &rejected) != nil || rejected.Error == "" {
					t.Fatal("upstream provider conflict accepted")
				}
			}
		})
	}
}
