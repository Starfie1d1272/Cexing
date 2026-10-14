package main

import (
	"core/configpipeline"
	"crypto/sha256"
	"encoding/json"
	"gopkg.in/yaml.v3"
	"os"
	"path/filepath"
	"testing"
)

func TestGlobalMergeAtomicScopeOrderAndSource(t *testing.T) {
	home := t.TempDir()
	// Full supplies the verified public model. Smart's process-wide once cache
	// must not first load a missing-model fixture before real forwarding tests.
	if modelPath := os.Getenv("SMART_REAL_MODEL"); modelPath != "" {
		model, err := os.ReadFile(modelPath)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, "Model.bin"), model, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	original := "# exact source 😀\r\nproxies: [{name: a, type: socks5, server: 192.0.2.1, port: 1080}, {name: b, type: socks5, server: 192.0.2.2, port: 1080}]\r\nproxy-groups: [{name: Auto, type: url-test, proxies: [a, b]}, {name: Main, type: select, proxies: [Auto, DIRECT]}]\r\nrules: ['MATCH,Main']\r\n\r\n"
	local := "# local exception\nhosts: {local.invalid: 192.0.2.4}\nproxy-groups: [{name: Auto, type: url-test, proxies: [b]}, {name: Main, type: select, proxies: [Auto, DIRECT]}]\nrules: ['DOMAIN,local.invalid,DIRECT', 'MATCH,Main']\ndns: {nameserver: [9.9.9.9]}\n"
	global := "profile: {store-selected: true}\nhosts: {global.invalid: 192.0.2.3}\nproxy-groups: [{name: Auto, type: fallback, proxies: [a]}, {name: Main, type: select, proxies: [Auto, DIRECT]}]\nrules: ['DOMAIN,global.invalid,DIRECT', 'MATCH,Main']\ndns: {listen: '0.0.0.0:53', nameserver: [1.1.1.1]}\nallow-lan: true\nexternal-controller: '0.0.0.0:9090'\n"
	stage := func(name, expected, overlay string, proposed *string) versionResponse {
		t.Helper()
		r, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: name, Expected: expected, Original: original, Overlay: overlay, Metadata: `{}`, SmartConversion: true, UpdateGlobal: proposed != nil, GlobalMerge: proposed})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	commit := func(v versionResponse, expected string, proposed *string) versionResponse {
		t.Helper()
		r, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: v.Version.ID, Expected: expected, Active: true, UpdateGlobal: proposed != nil, GlobalMerge: proposed})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	before := stage("one.yaml", "", local, nil)
	commit(before, "", nil)
	stale := stage("two.yaml", before.Version.ID, "", nil)
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: stale.Version.ID, Expected: before.Version.ID}); err != nil {
		t.Fatal(err)
	}
	oldState, _ := os.ReadFile(filepath.Join(home, "profile-versions/state.json"))
	preview, err := executeVersionAction(home, versionAction{Op: "merge-preview", Original: original, Overlay: local, Expected: before.Version.ID, GlobalMerge: &global, UpdateGlobal: true, SmartConversion: true})
	if err != nil || preview.MergePreview == nil {
		t.Fatal("preview", err)
	}
	response, err := json.Marshal(preview)
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(response, &envelope); err != nil {
		t.Fatal(err)
	}
	requireMergePreviewFields(t, envelope["mergePreview"])
	unchanged, _ := os.ReadFile(filepath.Join(home, "profile-versions/state.json"))
	if string(unchanged) != string(oldState) {
		t.Fatal("preview published global")
	}
	candidate := stage("one.yaml", before.Version.ID, local, &global)
	stillOld, _ := os.ReadFile(filepath.Join(home, "profile-versions/state.json"))
	if string(stillOld) != string(oldState) {
		t.Fatal("stage published global")
	}
	if _, err := executeVersionAction(home, versionAction{Op: "verify", VersionID: candidate.Version.ID, Expected: before.Version.ID, UpdateGlobal: true, GlobalMerge: &global}); err != nil {
		t.Fatal(err)
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: candidate.Version.ID, Expected: before.Version.ID, UpdateGlobal: true, GlobalMerge: &global}); err == nil {
		t.Fatal("inactive commit promoted global")
	}
	after := commit(candidate, before.Version.ID, &global)
	if after.State.GlobalMerge != global || after.State.Previous.ID != before.Version.ID {
		t.Fatal("global/current/previous were not published together")
	}
	inspect := func(v versionResponse) map[string]interface{} {
		t.Helper()
		bytes, err := os.ReadFile(v.Version.Path)
		if err != nil {
			t.Fatal(err)
		}
		var config map[string]interface{}
		if err := yaml.Unmarshal(bytes, &config); err != nil {
			t.Fatal(err)
		}
		return config
	}
	config := inspect(candidate)
	groups := config["proxy-groups"].([]interface{})
	auto := groups[0].(map[string]interface{})
	if auto["type"] != "smart" || len(auto["proxies"].([]interface{})) != 1 || auto["proxies"].([]interface{})[0] != "b" {
		t.Fatal("global/local arrays or Smart order changed", auto)
	}
	hosts := config["hosts"].(map[string]interface{})
	if hosts["local.invalid"] == nil || hosts["global.invalid"] != nil {
		t.Fatal("hosts were deep-merged", hosts)
	}
	rules := config["rules"].([]interface{})
	if len(rules) != 2 || rules[0] != "DOMAIN,local.invalid,DIRECT" {
		t.Fatal("rules appended or global overrode local", rules)
	}
	dns := config["dns"].(map[string]interface{})
	if dns["listen"] != "127.0.0.1:1053" || dns["nameserver"].([]interface{})[0] != "9.9.9.9" || config["allow-lan"] != false || config["external-controller"] != "127.0.0.1:9090" {
		t.Fatal("platform/local DNS priority changed", dns)
	}
	if _, err := executeVersionAction(home, versionAction{Op: "commit", VersionID: stale.Version.ID, Expected: candidate.Version.ID, Active: true}); err == nil {
		t.Fatal("old-global cached version activated")
	}
	fresh := stage("two.yaml", candidate.Version.ID, "", nil)
	config = inspect(fresh)
	if config["rules"].([]interface{})[0] != "DOMAIN,global.invalid,DIRECT" {
		t.Fatal("other profile missed common baseline")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(fresh.Version.Path), "overlay.yaml")); !os.IsNotExist(err) {
		t.Fatal("global incorrectly became local overlay")
	}
	if _, err := executeVersionAction(home, versionAction{Op: "verify", VersionID: stale.Version.ID, Expected: candidate.Version.ID}); err == nil {
		t.Fatal("stale-global verification accepted")
	}
	raw, _ := os.ReadFile(filepath.Join(filepath.Dir(candidate.Version.Path), "original.yaml"))
	overlay, _ := os.ReadFile(filepath.Join(filepath.Dir(candidate.Version.Path), "overlay.yaml"))
	if string(raw) != original || string(overlay) != local {
		t.Fatal("raw/local bytes changed")
	}
	sourceBytes, _ := os.ReadFile(filepath.Join(filepath.Dir(candidate.Version.Path), "source.json"))
	var source struct {
		GlobalMerge string
		Overlays    [][]byte
	}
	if json.Unmarshal(sourceBytes, &source) != nil || source.GlobalMerge != global || len(source.Overlays) != 1 || string(source.Overlays[0]) != local {
		t.Fatal("global/local provenance lost scope")
	}
	regionLocal := "proxy-groups: [{name: Main, type: select, proxies: [b]}]"
	region, err := executeVersionAction(home, versionAction{Op: "region-preview", Expected: candidate.Version.ID, Original: original, Overlay: regionLocal, RegionPlan: &configpipeline.RegionPlan{Selector: "Main"}})
	if err != nil || region.RegionPreview == nil || len(region.RegionPreview.Nodes) != 1 || region.RegionPreview.Nodes["b"] == "" {
		t.Fatal("region preview did not use both layers", err)
	}
	beforeFailure := mustState(t, home)
	credential := "secret: synthetic-runtime-only"
	if _, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: "two.yaml", Expected: candidate.Version.ID, Original: original, Metadata: `{}`, GlobalMerge: &credential, UpdateGlobal: true}); err == nil {
		t.Fatal("global persisted runtime credential")
	}
	broken := "rules: [MATCH,missing]"
	if _, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: "two.yaml", Expected: candidate.Version.ID, Original: original, Metadata: `{}`, GlobalMerge: &broken, UpdateGlobal: true}); err == nil {
		t.Fatal("invalid global accepted")
	}
	rejectedState, _ := os.ReadFile(filepath.Join(home, "profile-versions/state.json"))
	if string(rejectedState) != string(beforeFailure) {
		t.Fatal("rejected global changed effective pointer")
	}
	var persisted struct{ GlobalMerge string }
	if json.Unmarshal(rejectedState, &persisted) != nil || persisted.GlobalMerge != global {
		t.Fatal("failed global replaced baseline")
	}
	empty := ""
	disabled := stage("one.yaml", candidate.Version.ID, local, &empty)
	commit(disabled, candidate.Version.ID, &empty)
	cleared, err := executeVersionAction(home, versionAction{Op: "read"})
	if err != nil || cleared.State.GlobalMerge != "" {
		t.Fatal("disable global", err)
	}
	config = inspect(disabled)
	if config["rules"].([]interface{})[0] != "DOMAIN,local.invalid,DIRECT" {
		t.Fatal("disable lost local exception")
	}
	if string(mustFile(t, filepath.Join(filepath.Dir(disabled.Version.Path), "original.yaml"))) != original {
		t.Fatal("source changed after disable")
	}
	if sha256.Sum256(mustFile(t, before.Version.Path)) == sha256.Sum256(mustFile(t, candidate.Version.Path)) {
		t.Fatal("common baseline did not change generated config")
	}
	if string(mustFile(t, before.Version.Path)) != string(mustFile(t, disabled.Version.Path)) {
		t.Fatal("disabling global did not restore original/local generated config")
	}
	t.Logf("source SHA-256 unchanged: %x; generated before/with-global: %x / %x", sha256.Sum256(raw), sha256.Sum256(mustFile(t, before.Version.Path)), sha256.Sum256(mustFile(t, candidate.Version.Path)))
}
func mustFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func mustState(t *testing.T, home string) []byte {
	return mustFile(t, filepath.Join(home, "profile-versions/state.json"))
}
