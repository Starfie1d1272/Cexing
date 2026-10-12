package configpipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestUnsupportedYAMLTags(t *testing.T) {
	for name, input := range map[string]string{
		"root":                            "!policy\n" + original,
		"scalar":                          original + "custom: !policy value\n",
		"mapping":                         original + "custom: !policy {enabled: true}\n",
		"sequence":                        original + "custom: !policy [value]\n",
		"standard unsupported collection": original + "custom: !!set {value: null}\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := compiler().Compile(context.Background(), Request{Original: []byte(input)}); err == nil {
				t.Fatal("unsupported tag accepted")
			}
		})
	}
	c := compiler()
	if _, err := c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{[]byte("custom: !policy value\n")}}); err == nil {
		t.Fatal("overlay custom tag accepted")
	}
	if _, err := c.Compile(context.Background(), Request{Original: []byte(original), Strategy: func(_ context.Context, n *yaml.Node) error {
		set(n, "custom", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!policy", Value: "value"})
		return nil
	}}); err == nil {
		t.Fatal("callback custom tag accepted")
	}
}

func TestRuntimeControllerCredentialCannotBecomeCandidate(t *testing.T) {
	const syntheticCredential = "SYNTHETIC-RUNTIME-ONLY-NONSECRET"
	for _, stage := range []string{"original", "overlay", "strategy", "platform"} {
		t.Run(stage, func(t *testing.T) {
			c := compiler()
			r := Request{Original: []byte(original)}
			inject := func(_ context.Context, n *yaml.Node) error {
				set(n, "secret", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: syntheticCredential})
				return nil
			}
			switch stage {
			case "original":
				r.Original = append(r.Original, []byte("secret: "+syntheticCredential+"\n")...)
			case "overlay":
				r.Overlays = [][]byte{[]byte("secret: " + syntheticCredential + "\n")}
			case "strategy":
				r.Strategy = inject
			case "platform":
				c.Platform = inject
			}
			root := filepath.Join(t.TempDir(), "private")
			core := &fakeCore{}
			tx := Transaction{Compiler: c, Store: FileStore{Root: root}, Activator: core}
			result, err := tx.Apply(context.Background(), r)
			if err == nil {
				t.Fatal("runtime credential reached persisted candidate")
			}
			if strings.Contains(err.Error(), syntheticCredential) || len(result.YAML) != 0 || len(result.Changes) != 0 || core.calls != 0 {
				t.Fatal("credential escaped rejected compilation")
			}
			if _, err := os.Stat(root); !os.IsNotExist(err) {
				t.Fatal("rejected compilation wrote files")
			}
		})
	}
}

func TestFileStoreRejectsForgedSensitiveResult(t *testing.T) {
	for _, location := range []string{"yaml", "original", "overlay"} {
		t.Run(location, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "private")
			r := Result{Original: []byte(original), YAML: []byte(original)}
			injected := []byte(original + "secret: SYNTHETIC-RUNTIME-ONLY\n")
			switch location {
			case "yaml":
				r.YAML = injected
			case "original":
				r.Original = injected
			case "overlay":
				r.Overlays = [][]byte{[]byte("secret: SYNTHETIC-RUNTIME-ONLY\n")}
			}
			if _, err := (FileStore{Root: root}).Stage(context.Background(), r); err == nil {
				t.Fatal("direct Stage persisted runtime credential")
			}
			if _, err := os.Stat(root); !os.IsNotExist(err) {
				t.Fatal("rejected result wrote files")
			}
		})
	}
}

func TestRuntimeInjectionIsOutsidePersistentPipeline(t *testing.T) {
	const credential = "SYNTHETIC-RUNTIME-ONLY-NONSECRET"
	c := compiler()
	validated := false
	runtimeCredential := credential
	// Model security's preparePlatformConfig boundary: only the host's private
	// validator copy receives runtime credentials; that copy is never returned.
	c.Validate = func(_ context.Context, data []byte) error {
		n, err := parse(data)
		if err != nil {
			return err
		}
		set(n, "secret", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: runtimeCredential})
		runtimeBytes, err := yaml.Marshal(n)
		if err != nil {
			return err
		}
		validated = strings.Contains(string(runtimeBytes), runtimeCredential)
		return nil
	}
	store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
	tx := Transaction{Compiler: c, Store: store, Activator: &fakeCore{}}
	result, err := tx.Apply(context.Background(), Request{Original: []byte(original), Previous: []byte(original + "secret: " + credential + "\n")})
	if err != nil {
		t.Fatal(err)
	}
	if !validated || strings.Contains(string(result.YAML), credential) {
		t.Fatal("runtime validation/persistence separation")
	}
	for _, change := range result.Changes {
		if change.Section == "secret" {
			t.Fatal("runtime credential entered diff")
		}
	}
	runtimeCredential = "SYNTHETIC-ROTATED-RUNTIME-NONSECRET"
	next, err := c.Compile(context.Background(), Request{Original: []byte(original)})
	if err != nil || next.Digest != result.Digest || !bytes.Equal(next.YAML, result.YAML) {
		t.Fatal("runtime rotation changed persisted candidate identity")
	}
	state, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(state.Current.Path), "source.json"))
	if err != nil {
		t.Fatal(err)
	}
	var source struct {
		Original []byte
		Overlays [][]byte
	}
	if err := json.Unmarshal(data, &source); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(source.Original), credential) {
		t.Fatal("runtime credential entered provenance")
	}
	data, err = os.ReadFile(state.Current.Path)
	if err != nil || strings.Contains(string(data), credential) {
		t.Fatal("runtime credential entered successful YAML")
	}
}

func TestSupportedStandardTagsRemainUsable(t *testing.T) {
	input := original + `standard:
  text: !!str 123
  flag: !!bool true
  count: !!int 42
  ratio: !!float 1.25
  nothing: !!null null
  date: !!timestamp 2026-10-12
  binary: !!binary c3ludGhldGlj
  defaults: &defaults {enabled: true}
  merged: {<<: *defaults, value: !!str synthetic}
`
	if _, err := compiler().Compile(context.Background(), Request{Original: []byte(input)}); err != nil {
		t.Fatal(err)
	}
}

func TestSensitiveBoundaryPreservesLastSuccess(t *testing.T) {
	store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
	core := &fakeCore{}
	tx := Transaction{Compiler: compiler(), Store: store, Activator: core}
	if _, err := tx.Apply(context.Background(), Request{Original: []byte(original)}); err != nil {
		t.Fatal(err)
	}
	before, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	tx.Compiler.Platform = func(_ context.Context, n *yaml.Node) error {
		set(n, "secret", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "SYNTHETIC-RUNTIME-ONLY"})
		return nil
	}
	if _, err := tx.Apply(context.Background(), Request{Original: []byte(original), ExpectedActiveRevision: before.Current.ID}); err == nil {
		t.Fatal("sensitive candidate accepted")
	}
	after, err := store.Load(context.Background())
	if err != nil || after.Current.ID != before.Current.ID || core.current.ID != before.Current.ID || core.calls != 1 {
		t.Fatal("last success changed")
	}
	entries, err := os.ReadDir(store.Root)
	if err != nil || len(entries) != 2 {
		t.Fatal("rejected candidate left files")
	}
}

func TestRuntimeCredentialAliasesAndCaseCannotBypass(t *testing.T) {
	for _, suffix := range []string{"SECRET: null\n", "SECRET: ''\n", "defaults: &d {secret: SYNTHETIC-RUNTIME-ONLY}\n<<: *d\n"} {
		if _, err := compiler().Compile(context.Background(), Request{Original: []byte(original + suffix)}); err == nil {
			t.Fatal("credential persistence boundary bypassed")
		}
	}
}
