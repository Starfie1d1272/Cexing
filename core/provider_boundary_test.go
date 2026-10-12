package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestProviderSchemaBoundary(t *testing.T) {
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		for _, fields := range []string{
			"Type: http\n    Path: controller-security/secret",
			"TYPE: http\n    PATH: controller-security/secret",
			"Type: http\n    TYPE: file\n    Path: controller-security/secret",
			"type: http\n    path: providers/safe.yaml\n    Path: controller-security/secret",
			"type: http\n    path: controller-security/secret\n    Path: providers/safe.yaml",
			"Type: http\n    path: controller-security/secret",
			"type: http\n    Path: controller-security/secret",
			"type: 123\n    path: providers/safe.yaml",
			"type: http\n    path: 123",
			"type: http\n    path: null",
			"type: http\n    path: providers/safe.yaml\n    URL: http://127.0.0.1:1/alias",
		} {
			text := fmt.Sprintf("mixed-port: 0\ndns: {enable: false}\n%s:\n  synthetic:\n    %s\n    url: http://127.0.0.1:1/synthetic\n    behavior: domain\n", section, fields)
			if _, err := preparePlatformConfig(text, ""); err == nil {
				t.Errorf("accepted ambiguous or unsafe %s fields %q", section, fields)
			}
		}
		for _, path := range []string{"ui", "ui/index.html", "Model.bin", "model.bin", "MODEL.BIN", "geoip.metadb", "GeoSite.dat", "zashboard-staging-synthetic/index.html"} {
			for _, kind := range []string{"http", "file"} {
				text, _ := yaml.Marshal(map[string]any{section: map[string]any{"synthetic": map[string]any{"Type": kind, "Path": path, "url": "http://127.0.0.1:1/synthetic", "behavior": "domain"}}})
				if _, err := preparePlatformConfig(string(text), ""); err == nil {
					t.Errorf("accepted host-owned %s %s path %q", section, kind, path)
				}
			}
		}
		if err := os.MkdirAll(filepath.Join(home, "providers"), 0o700); err != nil {
			t.Fatal(err)
		}
		fixture := "proxies: [{name: synthetic, type: direct}]\n"
		if section == "rule-providers" {
			fixture = "payload: [example.test]\n"
		}
		if err := os.WriteFile(filepath.Join(home, "providers", "synthetic.yaml"), []byte(fixture), 0o600); err != nil {
			t.Fatal(err)
		}
		for _, kind := range []string{"http", "file"} {
			text, _ := yaml.Marshal(map[string]any{section: map[string]any{"synthetic": map[string]any{"Type": kind, "Path": "providers/synthetic.yaml", "URL": "http://127.0.0.1:1/synthetic", "behavior": "domain"}}})
			if _, err := preparePlatformConfig(string(text), ""); err != nil {
				t.Errorf("rejected normal case-alias %s %s provider: %v", section, kind, err)
			}
		}
	}
	if err := os.WriteFile(filepath.Join(home, "model.bin"), []byte("synthetic-model"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(home, "model.bin"), filepath.Join(home, "providers", "model-alias")); err != nil {
		t.Fatal(err)
	}
	if err := validateProviderPath("providers/model-alias"); err == nil {
		t.Fatal("accepted hardlink alias of case-insensitive model file")
	}
}
