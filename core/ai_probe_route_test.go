package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"core/configpipeline"
	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

func TestAIProbeAuthenticationAndRuntimeIdentity(t *testing.T) {
	if os.Getenv("CEXING_AI_ROUTE_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestAIProbeAuthenticationAndRuntimeIdentity$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_AI_ROUTE_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		return
	}
	homeDir = t.TempDir()
	if err := initControllerSecurity(homeDir); err != nil {
		t.Fatal(err)
	}
	if err := serveController(); err != nil {
		t.Fatal(err)
	}
	defer stopController()
	lastMessage := ""
	request := func(body, auth string) int {
		req, _ := http.NewRequest("POST", "http://"+defaultController+"/ohos/ai-probe", strings.NewReader(body))
		req.Header.Set("Authorization", auth)
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		bytes, _ := io.ReadAll(response.Body)
		if strings.Contains(string(bytes), controllerSecret) {
			t.Fatal("secret in response")
		}
		var reply map[string]string
		_ = json.Unmarshal(bytes, &reply)
		lastMessage = reply["message"]
		return response.StatusCode
	}
	if code := request(`{"revision":"version-synthetic"}`, ""); code != 401 {
		t.Fatal("unauthenticated route", code)
	}
	if code := request(`{"revision":"version-synthetic","url":"https://example.invalid"}`, "Bearer "+controllerSecret); code != 400 {
		t.Fatal("caller endpoint admitted", code)
	}
	if code := request(`{"revision":"version-synthetic"}`, "Bearer "+controllerSecret); code != 409 {
		t.Fatal("offline route pretended applied", code)
	}

	text := `proxies: [{name: one, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}]
proxy-groups: [{name: AI, type: select, proxies: [one]}]
rules: ["MATCH,AI"]
`
	parsed, err := config.Parse([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	store := configpipeline.FileStore{Root: filepath.Join(homeDir, "profile-versions")}
	version, err := store.Stage(context.Background(), configpipeline.Result{Original: []byte(text), YAML: []byte(text), ProfileID: "synthetic.yaml"})
	if err != nil {
		t.Fatal(err)
	}
	sourcePath := filepath.Join(store.Root, version.ID, "source.json")
	bytes, _ := os.ReadFile(sourcePath)
	var source map[string]any
	json.Unmarshal(bytes, &source)
	source["EditIntent"] = map[string]any{"schemaVersion": 1, "template": map[string]any{"templateId": "ai", "version": 1, "targetGroup": "AI"}}
	bytes, _ = json.Marshal(source)
	if err := os.WriteFile(sourcePath, bytes, 0600); err != nil {
		t.Fatal(err)
	}
	if err := store.Commit(context.Background(), configpipeline.Snapshot{Current: &version, Profiles: map[string]configpipeline.Version{"synthetic.yaml": version}}); err != nil {
		t.Fatal(err)
	}
	// Synthetic readiness marker only: no system TUN or device is created here.
	initialized = true
	tunListener = &sing_tun.Listener{}
	defer func() { tunListener = nil; initialized = false }()
	if _, err := activeAIProbeIdentity(version.ID); err == nil {
		t.Fatal("unobserved running config accepted")
	}
	observeAIProbeConfig(text + "# different\n")
	if _, err := activeAIProbeIdentity(version.ID); err == nil {
		t.Fatal("published/runtime mismatch accepted")
	}
	observeAIProbeConfig(text)
	id, err := activeAIProbeIdentity(version.ID)
	if err != nil || id.Group != "AI" || id.Revision != version.ID {
		t.Fatal("current applied identity rejected", err)
	}

	priorRuntime := id.Runtime
	observeAIProbeConfig(text)
	identical, epochErr := activeAIProbeIdentity(version.ID)
	if epochErr != nil || identical.Runtime == priorRuntime {
		t.Fatal("identical applied YAML reused old runtime identity", epochErr)
	}
	beforeRefresh, refreshErr := probeSelection("AI")
	if refreshErr != nil {
		t.Fatal(refreshErr)
	}
	refreshed, refreshErr := config.Parse([]byte(text))
	if refreshErr != nil {
		t.Fatal(refreshErr)
	}
	tunnel.UpdateProxies(refreshed.Proxies, refreshed.Providers)
	afterRefresh, refreshErr := probeSelection("AI")
	if refreshErr != nil || beforeRefresh == afterRefresh {
		t.Fatal("same-name proxy replacement reused old route/cache identity", refreshErr)
	}

	chained, chainErr := config.Parse([]byte(`proxies:
  - {name: chained, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic, dialer-proxy: hop}
  - {name: hop, type: direct}
proxy-groups: [{name: AI, type: select, proxies: [chained]}]
rules: ['MATCH,AI']
`))
	if chainErr != nil {
		t.Fatal(chainErr)
	}
	tunnel.UpdateProxies(chained.Proxies, chained.Providers)
	if _, err := probeSelection("AI"); err == nil {
		t.Fatal("mutable named dialer chain admitted without a pinned route")
	}
	if code := request(mustEditorJSON(t, aiProbeInput{Revision: version.ID}), "Bearer "+controllerSecret); code != 409 || lastMessage != "PROBE_ROUTE_UNPROVEN" {
		t.Fatal("unproven route did not remain unchecked", code, lastMessage)
	}

	empty, err := config.Parse([]byte(`proxy-providers:
  inline:
    type: inline
    payload: [{name: synthetic, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}]
proxy-groups: [{name: Empty, type: select, use: [inline], filter: '^absent$'}]
rules: ['MATCH,Empty']
`))
	if err != nil {
		t.Fatal(err)
	}
	tunnel.UpdateProxies(empty.Proxies, empty.Providers)
	if _, err := probeSelection("Empty"); err == nil {
		t.Fatal("implicit DIRECT empty fallback accepted")
	}
	if _, err := activeAIProbeIdentity("version-other"); err == nil {
		t.Fatal("stale revision accepted")
	}
}

func TestAIProbeTargetFollowsRenameAndRejectsReplacement(t *testing.T) {
	id := func(name string) string {
		b, _ := json.Marshal(map[string]any{"proxy-groups": []any{map[string]any{"name": name, "type": "select", "proxies": []string{"DIRECT"}}}})
		snapshot, err := configpipeline.ReadEditable(b, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, section := range snapshot.Sections {
			if section.Section == "proxy-groups" {
				return section.Items[0].ID
			}
		}
		t.Fatal("missing group")
		return ""
	}
	intent := &configpipeline.EditIntent{Template: &configpipeline.TemplatePlan{TargetGroup: "AI"}, Operations: []configpipeline.EditOperation{
		{Kind: "rename", Section: "proxy-groups", Target: id("AI"), Name: "chosen"},
		{Kind: "add", Section: "proxy-groups", Value: json.RawMessage(`{"name":"AI","type":"select","proxies":["DIRECT"]}`)},
		{Kind: "rename", Section: "proxy-groups", Target: id("AI"), Name: "shadow"},
		{Kind: "rename", Section: "proxy-groups", Target: id("chosen"), Name: "final"},
	}}
	if group, err := aiProbeTarget(intent); err != nil || group != "final" {
		t.Fatal("wrong renamed exit", group, err)
	}
	intent.Operations = append(intent.Operations, configpipeline.EditOperation{Kind: "delete", Section: "proxy-groups", Target: id("final")}, configpipeline.EditOperation{Kind: "add", Section: "proxy-groups", Value: json.RawMessage(`{"name":"final","type":"select","proxies":["DIRECT"]}`)})
	if _, err := aiProbeTarget(intent); err == nil {
		t.Fatal("deleted target replaced by unrelated group")
	}
}
