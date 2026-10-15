package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"core/configpipeline"
	"core/profiletemplates"
)

func TestTemplateUpdateRealSourceDeltaAndSuccessfulProvenance(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := `proxies: [{name: node, type: socks5, server: 192.0.2.1, port: 1080, udp: true}]
proxy-groups: [{name: Pick, type: select, proxies: [node]}, {name: Other, type: select, proxies: [node]}]
rules: ['MATCH,Pick']
x-unknown: {future: preserve}
`
	intent := &configpipeline.EditIntent{SchemaVersion: 1, Revision: "draft", SourceRevision: "source", Operations: []configpipeline.EditOperation{}, SmartGroups: map[string]bool{"private-choice": false}, Template: &configpipeline.TemplatePlan{TemplateID: "ai", Version: 1, TargetGroup: "Pick"}}
	c := configpipeline.Compiler{PrepareTemplate: editorTemplatePrepare(home)}
	r := configpipeline.Request{Original: []byte(original), Intent: intent}
	first, err := c.EditTarget(context.Background(), r, "rules", profiletemplates.TemplateTarget("ai", "ai/chatgpt"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.EditTarget(context.Background(), r, "rules", profiletemplates.TemplateTarget("ai", "ai/openai"))
	if err != nil {
		t.Fatal(err)
	}
	rawView, err := configpipeline.ReadEditable([]byte(original), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	node, err := configpipeline.ReadEditTarget([]byte(original), nil, nil, "proxies", rawView.Sections[0].Items[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	intent.Operations = []configpipeline.EditOperation{
		{ID: "personal-port", Kind: "update", Section: "proxies", Target: node.Item.ID, Preconditions: map[string]string{"port": node.Item.Fields["port"]}, Patch: json.RawMessage(`{"port":1081}`)},
		{ID: "personal-rule", Kind: "update", Section: "rules", Target: first.Item.ID, Expected: first.Item.Revision, Value: json.RawMessage(`"DOMAIN,personal.synthetic,Pick"`)},
		{ID: "personal-delete", Kind: "delete", Section: "rules", Target: second.Item.ID, Expected: second.Item.Revision},
		{ID: "personal-order", Kind: "move", Section: "rules", Target: first.Item.ID, Before: profiletemplates.TemplateTarget("ai", "ai/anthropic")},
	}
	stage := func(source string, value *configpipeline.EditIntent, expected string) configpipeline.Version {
		t.Helper()
		out, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: "synthetic.yaml", Original: source, Metadata: `{}`, Expected: expected, EditIntent: value})
		if err != nil {
			t.Fatal(err)
		}
		return *out.Version
	}
	commit := func(v configpipeline.Version, expected string) {
		t.Helper()
		if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: v.ID, ProfileID: v.ProfileID, Expected: expected, Active: true}); err != nil {
			t.Fatal(err)
		}
	}
	readIntent := func(v configpipeline.Version) *configpipeline.EditIntent {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(filepath.Dir(v.Path), "source.json"))
		if err != nil {
			t.Fatal(err)
		}
		var src struct{ EditIntent *configpipeline.EditIntent }
		if json.Unmarshal(b, &src) != nil || src.EditIntent == nil {
			t.Fatal("missing successful intent")
		}
		return src.EditIntent
	}
	v := stage(original, intent, "")
	commit(v, "")
	saved := readIntent(v)
	saved.Template.TargetGroup = "Other"
	latest := strings.Replace(original, "udp: true", "udp: false", 1)
	source := templateUpdateSourceInput{ProfileID: v.ProfileID, ProfileVersion: v.ID, Original: latest, Intent: json.RawMessage(mustEditorJSON(t, saved)), Action: "read"}
	reply, err := templateUpdateSource(home, source)
	if err != nil {
		t.Fatal(err)
	}
	preview, err := profiletemplates.PreviewUpdate(context.Background(), *reply.Request)
	if err != nil || preview.Ready || len(preview.Conflicts) == 0 {
		t.Fatal("changed target failed to expose incompatible personal rules", err)
	}
	decisions := map[string]string{}
	for _, conflict := range preview.Conflicts {
		decisions[conflict.ID] = "mine"
	}
	reply.Request.Decisions = decisions
	preview, err = profiletemplates.PreviewUpdate(context.Background(), *reply.Request)
	if err != nil || !preview.Ready {
		t.Fatal("explicit choices did not resolve", err)
	}
	source.Action = "encode"
	source.Stamp = reply.Stamp
	source.Candidate = preview.Candidate
	encoded, err := templateUpdateSource(home, source)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded.Intent.Operations) == 0 || encoded.Intent.SmartGroups["private-choice"] != false {
		t.Fatal("personal intent lost")
	}
	state, err := (configpipeline.FileStore{Root: filepath.Join(home, "profile-versions")}).Load(context.Background())
	if err != nil || state.Current.ID != v.ID {
		t.Fatal("read/encode published", err)
	}
	old, _ := os.ReadFile(filepath.Join(filepath.Dir(v.Path), "original.yaml"))
	if string(old) != original {
		t.Fatal("source rewritten before apply")
	}
	changed := source
	changed.Original += "\nx-late: changed\n"
	if _, err := templateUpdateSource(home, changed); err == nil {
		t.Fatal("stale source receipt accepted")
	}
	next := stage(latest, encoded.Intent, v.ID)
	commit(next, v.ID)
	generated, _ := os.ReadFile(next.Path)
	for _, want := range []string{"personal.synthetic", "1081", "udp: false", "future: preserve", "gemini.google.com,Other"} {
		if !strings.Contains(string(generated), want) {
			t.Fatal("chosen delta/advanced source lost", want)
		}
	}
	if strings.Contains(string(generated), "DOMAIN-SUFFIX,openai.com,") {
		t.Fatal("deletion resurrected")
	}
	successful := readIntent(next)
	if successful.Template.Baseline == nil || successful.Template.Mine == nil || len(successful.Template.Mine.Deleted) != 1 {
		t.Fatal("successful private provenance lost")
	}
	// A second real same-version subscription rebase, including JSON restart.
	restart, err := configpipeline.DecodeEditIntent([]byte(mustEditorJSON(t, successful)))
	if err != nil {
		t.Fatal(err)
	}
	source = templateUpdateSourceInput{ProfileID: next.ProfileID, ProfileVersion: next.ID, Original: latest + "x-next: preserved\n", Intent: json.RawMessage(mustEditorJSON(t, restart)), Action: "read"}
	again, err := templateUpdateSource(home, source)
	if err != nil {
		t.Fatal(err)
	}
	ready, err := profiletemplates.PreviewUpdate(context.Background(), *again.Request)
	if err != nil || !ready.Ready {
		t.Fatal("repeat rebase not stable", err)
	}
	source.Action = "encode"
	source.Stamp = again.Stamp
	source.Candidate = ready.Candidate
	againEncoded, err := templateUpdateSource(home, source)
	if err != nil {
		t.Fatal(err)
	}
	final := stage(source.Original, againEncoded.Intent, next.ID)
	data, _ := os.ReadFile(final.Path)
	if strings.Contains(string(data), "DOMAIN-SUFFIX,openai.com,") || !strings.Contains(string(data), "x-next: preserved") {
		t.Fatal("repeat rebase resurrected deletion/lost unknown field")
	}
	if !sameTemplateSnapshot(readIntent(final).Template.Mine, successful.Template.Mine) {
		t.Fatal("second rebase changed personal template result")
	}
	// An unrepresentable structured numeric edit is rejected before it can
	// round-trip through ArkTS or replace the successful pointer.
	riskyBytes, _ := json.Marshal(successful)
	risky, _ := configpipeline.DecodeEditIntent(riskyBytes)
	risky.Operations = append(risky.Operations, configpipeline.EditOperation{ID: "large-advanced", Kind: "update", Section: "proxies", Target: node.Item.ID, Preconditions: map[string]string{"x-large": node.MissingFieldRevision}, Patch: json.RawMessage(`{"x-large":9007199254740993}`)})
	preciseSource := templateUpdateSourceInput{ProfileID: next.ProfileID, ProfileVersion: next.ID, Original: latest, Intent: json.RawMessage(mustEditorJSON(t, risky)), Action: "read"}
	if _, err := templateUpdateSource(home, preciseSource); err == nil || err.Error() != "TEMPLATE_UPDATE_PRECISION" {
		t.Fatal("inexact advanced data admitted", err)
	}
	current, _ := (configpipeline.FileStore{Root: filepath.Join(home, "profile-versions")}).Load(context.Background())
	if current.Current.ID != next.ID {
		t.Fatal("rejected advanced field changed Current")
	}
	// Caller-supplied home/URL fields are rejected by the actual bounded envelope.
	invalid := `{"op":"template-update-preview","source":{"profileId":"synthetic.yaml","url":"https://synthetic.invalid"}}`
	if !strings.Contains(coreTemplateUpdateAction(invalid, home), `"error"`) {
		t.Fatal("unexpected source URL accepted")
	}
}
