package proxyformstest

import (
	"bytes"
	"context"
	"core/configpipeline"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor"
	"gopkg.in/yaml.v3"
)

// Native form models -> actual intent compiler -> pinned Mihomo parser.
// Disposable process, synthetic loopback nodes and inline provider; no Start/network.
func TestNativeProxyFormsReachCompilerAndParser(t *testing.T) {
	if os.Getenv("CE_XING_PROXY_FORM_CHILD") != "1" {
		for _, mode := range []string{"fields", "rename", "link-ss", "link-vmess", "link-vless", "link-trojan"} {
			t.Run(mode, func(t *testing.T) {
				child := exec.Command(os.Args[0], "-test.run=^TestNativeProxyFormsReachCompilerAndParser$", "-test.v")
				child.Env = append(os.Environ(), "CE_XING_PROXY_FORM_CHILD=1", "CE_XING_PROXY_FORM_MODE="+mode)
				if output, err := child.CombinedOutput(); err != nil {
					t.Fatalf("child: %v\n%s", err, output)
				}
			})
		}
		return
	}
	mode := os.Getenv("CE_XING_PROXY_FORM_MODE")
	rename := mode == "rename"
	expectedName := "original-node"
	if rename {
		expectedName = "renamed-node"
	}
	source := []byte(`proxies:
  - {name: original-node, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: synthetic-password, x-advanced: {keep: true}}
proxy-providers:
  source: {type: inline, payload: [{name: from-provider, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: synthetic-password}]}
proxy-groups:
  - {name: main, type: select, proxies: [original-node], use: [source]}
  - {name: only-provider, type: select, use: [source]}
rules: ['MATCH,main']
x-top-level: {keep: true}
`)
	snapshot, err := configpipeline.ReadEditable(source, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	targets := map[string]configpipeline.EditTarget{}
	for _, section := range snapshot.Sections {
		if section.Section != "proxies" && section.Section != "proxy-providers" {
			continue
		}
		target, err := configpipeline.ReadEditTarget(source, nil, nil, section.Section, section.Items[0].ID)
		if err != nil {
			t.Fatal(err)
		}
		targets[section.Section] = target
	}
	links := map[string]string{
		"link-ss":     "ss://aes-128-gcm:synthetic@127.0.0.1:443#Imported",
		"link-vless":  "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?encryption=none&type=ws&security=tls&path=%2Fsynthetic#Imported",
		"link-trojan": "trojan://synthetic@127.0.0.1:443?security=tls#Imported",
		"link-vmess":  "vmess://" + base64.StdEncoding.EncodeToString([]byte(`{"v":"2","ps":"Imported","add":"127.0.0.1","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","net":"grpc","path":"synthetic","tls":"tls"}`)),
	}
	input, _ := json.Marshal(map[string]any{"sourceRevision": snapshot.SourceRevision, "node": targets["proxies"],
		"provider": targets["proxy-providers"], "missing": configpipeline.MissingFieldRevision(), "rename": rename, "link": links[mode]})
	root, _ := filepath.Abs("../..")
	command := exec.Command("node", "scripts/emit-proxy-form-fixture.cjs")
	command.Dir = root
	command.Stdin = bytes.NewReader(input)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("native form fixture: %v\n%s", err, output)
	}
	intent, err := configpipeline.DecodeEditIntent(output)
	if err != nil {
		t.Fatal(err)
	}
	compiler := configpipeline.Compiler{Platform: func(context.Context, *yaml.Node) error { return nil },
		Validate: func(_ context.Context, data []byte) error { _, err := config.Parse(data); return err }}
	generated, err := compiler.Compile(context.Background(), configpipeline.Request{Original: source, Intent: intent})
	if err != nil {
		t.Fatalf("compile: %#v", err)
	}
	if _, err := config.Parse(generated.YAML); err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := yaml.Unmarshal(generated.YAML, &value); err != nil {
		t.Fatal(err)
	}
	node := value["proxies"].([]any)[0].(map[string]any)
	if node["name"] != expectedName || node["port"] != 8443 || node["udp"] != true {
		t.Fatal("native node fields were not compiled")
	}
	if node["x-advanced"].(map[string]any)["keep"] != true || value["x-top-level"].(map[string]any)["keep"] != true {
		t.Fatal("unknown fields were dropped")
	}
	if strings.HasPrefix(mode, "link-") {
		nodes := value["proxies"].([]any)
		if len(nodes) != 2 || nodes[1].(map[string]any)["name"] != "Imported" {
			t.Fatal("imported node not published")
		}
		if nodes[1].(map[string]any)["type"] != strings.TrimPrefix(mode, "link-") {
			t.Fatal("imported protocol changed")
		}
	}
	groups := value["proxy-groups"].([]any)
	if groups[0].(map[string]any)["proxies"].([]any)[0] != expectedName {
		t.Fatal("rename did not update group references")
	}
	if len(groups) != 3 {
		t.Fatal("provider-only group addition missing")
	}
}
