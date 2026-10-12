package configpipeline

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const original = `# synthetic subscription; keep these exact bytes
proxies:
  - {name: node, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}
proxy-groups:
  - {name: pick, type: select, proxies: [node]}
rules: ["DOMAIN,example.test,pick", "MATCH,DIRECT"]
dns:
  nameserver-policy:
    '+.z.test': 1.1.1.1
    '+.a.test': 8.8.8.8
`

func compiler() Compiler {
	return Compiler{
		Platform: func(_ context.Context, n *yaml.Node) error {
			set(n, "external-controller", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "127.0.0.1:9090"})
			return nil
		},
		Validate: func(context.Context, []byte) error { return nil }, // mock: never a claim of full kernel validation
	}
}
func TestMergeUpdateAndIdempotence(t *testing.T) {
	overlay := []byte(`proxies:
  - {name: node, port: 8443}
proxy-groups:
  - {name: generated, type: select, proxies: [pick]}
rules: ["DOMAIN,example.test,generated", "DOMAIN,example.test,pick", "MATCH,DIRECT", "MATCH,DIRECT"]
dns: {enable: true}
external-controller: 0.0.0.0:9999
`)
	c := compiler()
	r := Request{Original: []byte(original), Overlays: [][]byte{overlay, overlay}}
	a, err := c.Compile(context.Background(), r)
	if err != nil {
		t.Fatal(err)
	}
	b, err := c.Compile(context.Background(), Request{Original: a.YAML, Overlays: [][]byte{overlay}})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a.YAML, b.YAML) {
		t.Fatalf("not idempotent\n%s\n%s", a.YAML, b.YAML)
	}
	if !bytes.Equal(a.Original, []byte(original)) {
		t.Fatal("original not preserved")
	}
	n, _ := parse(a.YAML)
	if field(rootFirst(n, "proxies"), "server").Value != "192.0.2.1" || field(rootFirst(n, "proxies"), "port").Value != "8443" {
		t.Fatal("named deep merge lost node")
	}
	if field(n, "rules").Content[0].Value != "DOMAIN,example.test,generated" || field(n, "rules").Content[1].Value != "DOMAIN,example.test,pick" {
		t.Fatal("first-match rule order changed")
	}
	if size(field(n, "rules")) != 3 || !strings.Contains(string(a.YAML), "127.0.0.1:9090") {
		t.Fatal("rules or platform")
	}
	if strings.Index(string(a.YAML), "+.z.test") > strings.Index(string(a.YAML), "+.a.test") {
		t.Fatal("ordered mapping reordered")
	}
	updated := strings.Replace(original, "192.0.2.1", "192.0.2.2", 1)
	next, err := c.Compile(context.Background(), Request{Original: []byte(updated), Overlays: [][]byte{overlay}, Previous: a.YAML})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(next.YAML), "192.0.2.2") || !strings.Contains(string(next.YAML), "8443") {
		t.Fatal("update lost source or overlay")
	}
	for _, change := range next.Changes {
		if strings.Contains(change.Section, "192.") {
			t.Fatal("summary leaks values")
		}
	}
}
func rootFirst(n *yaml.Node, key string) *yaml.Node { return field(n, key).Content[0] }
func TestYAMLAndDeletion(t *testing.T) {
	c := compiler()
	aliases := []byte(`defaults: &defaults {enabled: true, value: 1}
settings: {<<: *defaults, value: 2}
`)
	out, err := c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{aliases, []byte("proxy-groups:\n  - {name: pick, $delete: true}\nrules: [MATCH,DIRECT]\ndns: null\n")}})
	// Use quoted rule because YAML flow sequence splits commas.
	if err == nil {
		t.Fatal("malformed rules accepted")
	}
	out, err = c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{aliases, []byte("proxy-groups:\n  - {name: pick, $delete: true}\nrules: ['MATCH,DIRECT']\ndns: null\n")}})
	if err != nil {
		t.Fatal(err)
	}
	n, _ := parse(out.YAML)
	if size(field(n, "proxy-groups")) != 0 || field(n, "dns") != nil || field(field(n, "settings"), "value").Value != "2" {
		t.Fatal("alias or delete semantics")
	}
}
func TestInvalidInputsAndReferences(t *testing.T) {
	for name, input := range map[string]string{
		"duplicate keys": original + "dns: {}\n", "multi document": original + "---\n{}\n", "non string keys": original + "other: {1: test}\n", "cycle": original + "other: &a {x: *a}\n",
		"missing node":          strings.Replace(original, "proxies: [node]", "proxies: [absent]", 1),
		"missing rule group":    strings.Replace(original, "example.test,pick", "example.test,absent", 1),
		"missing provider":      strings.Replace(original, "proxies: [node]", "use: [absent]", 1),
		"missing rule provider": strings.Replace(original, "DOMAIN,example.test,pick", "RULE-SET,absent,pick", 1),
		"group cycle":           strings.Replace(original, "proxies: [node]", "proxies: [pick]", 1),
		"empty":                 "rules: ['MATCH,DIRECT']\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := compiler().Compile(context.Background(), Request{Original: []byte(input)}); err == nil {
				t.Fatal("accepted invalid input")
			}
		})
	}
}
func TestProviderOnlyAndHooks(t *testing.T) {
	input := []byte(`proxy-providers:
  feed:
    type: inline
    payload: [{name: node, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}]
proxy-groups: [{name: pick, type: select, use: [feed]}]
rules: ['MATCH,pick']
`)
	c := compiler()
	order := ""
	c.Platform = func(_ context.Context, n *yaml.Node) error { order += "platform;"; return nil }
	c.Validate = func(_ context.Context, b []byte) error { order += "validate;"; return nil }
	_, err := c.Compile(context.Background(), Request{Original: input, Strategy: func(_ context.Context, n *yaml.Node) error { order += "strategy;"; return nil }})
	if err != nil || order != "strategy;platform;validate;" {
		t.Fatalf("%s %v", order, err)
	}
	c.Validate = func(context.Context, []byte) error { return errors.New("private-token") }
	if _, err := c.Compile(context.Background(), Request{Original: input}); err == nil || strings.Contains(err.Error(), "private-token") {
		t.Fatal("validator failure leaked or ignored")
	}
	c.Platform = nil
	if _, err := c.Compile(context.Background(), Request{Original: input}); err == nil {
		t.Fatal("platform optional")
	}
}

type failingStore struct {
	Store
	stageFail, commitFail bool
}

func (s failingStore) Stage(ctx context.Context, r Result) (Version, error) {
	if s.stageFail {
		return Version{}, errors.New("secret")
	}
	return s.Store.Stage(ctx, r)
}
func (s failingStore) Commit(ctx context.Context, v Snapshot) error {
	if s.commitFail {
		return errors.New("secret")
	}
	return s.Store.Commit(ctx, v)
}

type fakeCore struct {
	current            *Version
	fail, rollbackFail bool
	cancel             context.CancelFunc
	calls              int
}

func (a *fakeCore) Activate(_ context.Context, v Version) error {
	a.calls++
	a.current = &v
	if a.cancel != nil {
		a.cancel()
	}
	if a.fail {
		return errors.New("secret")
	}
	return nil
}
func (a *fakeCore) Restore(_ context.Context, v *Version) error {
	if a.rollbackFail {
		return errors.New("secret")
	}
	a.current = v
	return nil
}
func TestTransactions(t *testing.T) {
	for _, scenario := range []string{"compile", "save", "activate", "commit", "cancel", "rollback"} {
		t.Run(scenario, func(t *testing.T) {
			store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
			core := &fakeCore{}
			tx := Transaction{Compiler: compiler(), Store: store, Activator: core}
			ctx := context.Background()
			if _, err := tx.Apply(ctx, Request{Original: []byte(original)}); err != nil {
				t.Fatal(err)
			}
			before, err := store.Load(ctx)
			if err != nil {
				t.Fatal(err)
			}
			request := Request{ExpectedActiveRevision: before.Current.ID, Original: []byte(strings.Replace(original, "192.0.2.1", "192.0.2.2", 1))}
			switch scenario {
			case "compile":
				request.Original = []byte("invalid")
			case "save":
				tx.Store = failingStore{Store: store, stageFail: true}
			case "activate":
				core.fail = true
			case "commit":
				tx.Store = failingStore{Store: store, commitFail: true}
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				core.cancel = cancel
			case "rollback":
				core.fail = true
				core.rollbackFail = true
			}
			_, err = tx.Apply(ctx, request)
			if err == nil {
				t.Fatal("failure not reported")
			}
			if strings.Contains(err.Error(), "secret") {
				t.Fatal("error leaked")
			}
			after, loadErr := store.Load(context.Background())
			if loadErr != nil || after.Current.ID != before.Current.ID {
				t.Fatal("failed transaction changed successful pointer")
			}
			if scenario != "rollback" && core.current.ID != before.Current.ID {
				t.Fatal("core not restored")
			}
			if scenario == "rollback" {
				var failure *Failure
				if !errors.As(err, &failure) || !failure.RollbackFailed {
					t.Fatal("rollback failure hidden")
				}
			}
		})
	}
}
func TestSuccessfulVersionsAndPrivateFiles(t *testing.T) {
	store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
	tx := Transaction{Compiler: compiler(), Store: store, Activator: &fakeCore{}}
	for i := 0; i < 2; i++ {
		prior, _ := store.Load(context.Background())
		revision := ""
		if prior.Current != nil {
			revision = prior.Current.ID
		}
		if _, err := tx.Apply(context.Background(), Request{ExpectedActiveRevision: revision, Original: []byte(original)}); err != nil {
			t.Fatal(err)
		}
	}
	state, err := store.Load(context.Background())
	if err != nil || state.Previous == nil || state.Current.ID == state.Previous.ID {
		t.Fatal("previous success missing")
	}
	for _, path := range []string{state.Current.Path, filepath.Join(filepath.Dir(state.Current.Path), "source.json"), filepath.Join(store.Root, "state.json")} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm()&0077 != 0 {
			t.Fatal("private permissions")
		}
	}
	if err := store.Discard(context.Background(), *state.Previous); err == nil {
		t.Fatal("discarded successful version")
	}
}

func TestGenerationAndRealSaveFailures(t *testing.T) {
	c := compiler()
	_, err := c.Compile(context.Background(), Request{Original: []byte(original), Strategy: func(_ context.Context, n *yaml.Node) error {
		n.Content = append(n.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "broken"}, &yaml.Node{Kind: yaml.AliasNode, Value: "missing"})
		return nil
	}})
	if err == nil {
		t.Fatal("invalid generated YAML accepted")
	}
	blocked := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocked, []byte("occupied"), 0600); err != nil {
		t.Fatal(err)
	}
	store := FileStore{Root: blocked}
	if _, err := store.Stage(context.Background(), Result{Original: []byte(original), YAML: []byte(original)}); err == nil {
		t.Fatal("real save failure not detected")
	}
	if data, err := os.ReadFile(blocked); err != nil || string(data) != "occupied" {
		t.Fatal("save damaged preexisting file")
	}
	_, err = c.Compile(context.Background(), Request{Original: []byte(original), Overlays: [][]byte{[]byte("proxy-providers: {bad: {type: http, url: 'https://placeholder.invalid/feed'}}")}})
	if err == nil {
		t.Fatal("placeholder provider accepted")
	}
}

func TestStaleUpdateDoesNotActivate(t *testing.T) {
	store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
	core := &fakeCore{}
	tx := Transaction{Compiler: compiler(), Store: store, Activator: core}
	if _, err := tx.Apply(context.Background(), Request{Original: []byte(original)}); err != nil {
		t.Fatal(err)
	}
	before, _ := store.Load(context.Background())
	if _, err := tx.Apply(context.Background(), Request{Original: []byte(original)}); !errors.Is(err, ErrStaleRevision) {
		t.Fatal("stale update accepted")
	}
	after, _ := store.Load(context.Background())
	if core.calls != 1 || after.Current.ID != before.Current.ID {
		t.Fatal("stale update changed active state")
	}
}

func TestConcurrentUpdatesUseRevision(t *testing.T) {
	store := FileStore{Root: filepath.Join(t.TempDir(), "private")}
	core := &fakeCore{}
	tx := Transaction{Compiler: compiler(), Store: store, Activator: core}
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() { _, err := tx.Apply(context.Background(), Request{Original: []byte(original)}); results <- err }()
	}
	successes, stale := 0, 0
	for i := 0; i < 2; i++ {
		err := <-results
		if err == nil {
			successes++
		} else if errors.Is(err, ErrStaleRevision) {
			stale++
		} else {
			t.Fatal(err)
		}
	}
	if successes != 1 || stale != 1 || core.calls != 1 {
		t.Fatal("concurrent updates overwrote selection")
	}
}
