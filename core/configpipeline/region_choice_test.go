package configpipeline

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegionChoiceStagesWithOriginalAndIntentBeforeOnePublication(t *testing.T) {
	ctx := context.Background()
	store := FileStore{Root: filepath.Join(t.TempDir(), "versions")}
	choice := &RegionChoice{Pending: "Main", Previous: &RegionPreviousChoice{Selector: "Old", Name: "Manual"}}
	intent := &EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []EditOperation{}}
	result := Result{Original: []byte("proxies: []\n"), YAML: []byte("proxies: []\n"), ProfileID: "one.yaml", Metadata: `{"origin":"synthetic"}`, EditIntent: intent}
	version, err := store.StageWithRegionChoice(ctx, result, choice)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := store.Load(ctx)
	if err != nil || snapshot.Current != nil {
		t.Fatalf("stage published: %+v %v", snapshot, err)
	}
	data, err := os.ReadFile(filepath.Join(store.Root, version.ID, "source.json"))
	if err != nil {
		t.Fatal(err)
	}
	var source struct {
		RegionChoice *RegionChoice
		Original     []byte
		Metadata     string
		EditIntent   *EditIntent
	}
	if json.Unmarshal(data, &source) != nil || source.RegionChoice.Pending != "Main" || source.RegionChoice.Previous.Name != "Manual" || string(source.Original) != string(result.Original) || source.Metadata != result.Metadata || source.EditIntent.Revision != "draft" {
		t.Fatalf("lost atomic provenance: %s", data)
	}
	snapshot.Current = &version
	snapshot.Profiles = map[string]Version{"one.yaml": version}
	if err := store.Publish(ctx, snapshot); err != nil {
		t.Fatal(err)
	}
	reloaded, err := store.Load(ctx)
	if err != nil || reloaded.Current.ID != version.ID {
		t.Fatal("publication lost", err)
	}
}
func TestRegionChoiceRejectsInvalidStateBeforeCreatingFiles(t *testing.T) {
	root := filepath.Join(t.TempDir(), "absent")
	for _, choice := range []*RegionChoice{{Pending: strings.Repeat("a", 4097)}, {Previous: &RegionPreviousChoice{Name: "Manual"}}, {Previous: &RegionPreviousChoice{Selector: "Main"}}} {
		if _, err := (FileStore{Root: root}).StageWithRegionChoice(context.Background(), Result{}, choice); err == nil {
			t.Fatal("invalid state accepted")
		}
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("invalid choice wrote files", err)
	}
}
