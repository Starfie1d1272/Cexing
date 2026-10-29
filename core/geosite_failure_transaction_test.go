package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func TestMissingGeoSiteStagePreservesActiveAndRetries(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	writeGeoSite := func(name string) {
		t.Helper()
		raw, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: name, Domain: []*router.Domain{{Type: router.Domain_Domain, Value: "example.invalid"}}}}})
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(home, "geosite.dat"), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeGeoSite("fixture-only")
	base := "proxies: [{name: synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\nrules: ['MATCH,DIRECT']\n"
	first, err := executeVersionAction(home, versionAction{Op: "stage", ProfileID: "old.yaml", Original: base, Metadata: `{}`})
	if err != nil || first.Version == nil {
		t.Fatalf("initial stage: %v", err)
	}
	if _, err = executeVersionAction(home, versionAction{Op: "commit", VersionID: first.Version.ID, ProfileID: "old.yaml", Active: true}); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(home, "profile-versions", "state.json")
	before, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	candidate := base + "dns:\n  enable: true\n  nameserver: [127.0.0.1]\n  fallback: [127.0.0.1]\n  fallback-filter: {geoip: false, geosite: [win-extra]}\n"
	act := versionAction{Op: "stage", ProfileID: "new.yaml", Original: candidate, Metadata: `{}`, Expected: first.Version.ID}
	raw, err := json.Marshal(act)
	if err != nil {
		t.Fatal(err)
	}
	result := coreVersionAction(home, string(raw))
	if !strings.Contains(result, `"error":"GEOSITE_MISSING:win-extra"`) {
		t.Fatalf("missing category lost: %s", result)
	}
	after, err := os.ReadFile(statePath)
	if err != nil || string(after) != string(before) {
		t.Fatal("failed stage changed current state")
	}
	bundle := coreDiagnosticAction(home, `{"op":"diagnostics-export"}`)
	if !strings.Contains(bundle, `GEOSITE_MISSING`) || strings.Contains(bundle, "win-extra") || strings.Contains(bundle, "192.0.2.1") {
		t.Fatal("diagnostic leaked category/config or lost fixed code")
	}
	writeGeoSite("win-extra")
	staged, err := executeVersionAction(home, act)
	if err != nil || staged.Version == nil {
		t.Fatalf("retry stage: %v", err)
	}
	if _, err = executeVersionAction(home, versionAction{Op: "commit", VersionID: staged.Version.ID, ProfileID: "new.yaml", Expected: first.Version.ID, Active: true}); err != nil {
		t.Fatalf("retry commit: %v", err)
	}
}
