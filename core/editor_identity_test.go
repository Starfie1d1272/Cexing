package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEditorIdentityBindsLocalResourcesAndSettings(t *testing.T) {
	home := t.TempDir()
	if e := os.MkdirAll(filepath.Dir(filepath.Join(home, controllerSecretFile)), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(home, controllerSecretFile), []byte("synthetic-private"), 0600); e != nil {
		t.Fatal(e)
	}
	original := "proxy-providers: {pool: {type: file, path: pool.yaml}}\nproxy-groups: [{name: Main, type: select, use: [pool]}]\nrules: [\"MATCH,Main\"]\n"
	a := versionAction{Original: original, Overrides: `{"ipv6":false}`}
	first, e := editorIdentity(home, a, "")
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(filepath.Join(home, "pool.yaml"), []byte("proxies: []\n"), 0600)
	second, e := editorIdentity(home, a, "")
	if e != nil || second == first {
		t.Fatal("missing to present", e)
	}
	os.WriteFile(filepath.Join(home, "pool.yaml"), []byte("proxies: [invalid]\n"), 0600)
	third, e := editorIdentity(home, a, "")
	if e != nil || third == second {
		t.Fatal("changed invalid bytes", e)
	}
	a.Overrides = `{"ipv6":true}`
	fourth, e := editorIdentity(home, a, "")
	if e != nil || fourth == third {
		t.Fatal("settings not bound", e)
	}
	a.Metadata = `{"origin":"candidate"}`
	fifth, e := editorIdentity(home, a, "")
	if e != nil || fifth == fourth {
		t.Fatal("candidate metadata not bound", e)
	}
}
