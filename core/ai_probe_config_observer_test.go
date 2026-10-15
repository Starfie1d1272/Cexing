package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"core/configpipeline"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

// Real authenticated reload/parser/executor, isolated from other global core
// tests. The listener below is only a readiness marker; no system TUN is opened.
func TestAIProbeConfigObserverFollowsAppliedConfigAndPublishedPointer(t *testing.T) {
	if os.Getenv("CEXING_AI_OBSERVER_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestAIProbeConfigObserverFollowsAppliedConfigAndPublishedPointer$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_AI_OBSERVER_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("observer child: %v\n%s", err, out)
		}
		return
	}
	homeDir = t.TempDir()
	C.SetHomeDir(homeDir)
	if err := initControllerSecurity(homeDir); err != nil {
		t.Fatal(err)
	}
	if err := serveController(); err != nil {
		t.Fatal(err)
	}
	initialized = true
	activeOverrides = `{"mixedPort":0}`
	defer func() { tunListener = nil; initialized = false; stopController() }()
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	reload := func(text, auth string) int {
		body, _ := json.Marshal(map[string]string{"payload": text})
		req, _ := http.NewRequest(http.MethodPut, "http://"+defaultController+"/configs", strings.NewReader(string(body)))
		req.Header.Set("Authorization", auth)
		req.Header.Set("Content-Type", "application/json")
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		_, _ = io.Copy(io.Discard, response.Body)
		return response.StatusCode
	}
	digest := func(text string) string { sum := sha256.Sum256([]byte(text)); return hex.EncodeToString(sum[:]) }
	observed := func() string { runLock.Lock(); defer runLock.Unlock(); return aiAppliedDigest }
	store := configpipeline.FileStore{Root: filepath.Join(homeDir, "profile-versions")}
	stage := func(profile, text string) configpipeline.Version {
		version, err := store.Stage(context.Background(), configpipeline.Result{Original: []byte(text), YAML: []byte(text), ProfileID: profile})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(filepath.Dir(version.Path), "source.json")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var source map[string]any
		if err = json.Unmarshal(data, &source); err != nil {
			t.Fatal(err)
		}
		source["EditIntent"] = map[string]any{"schemaVersion": 1, "template": map[string]any{"templateId": "ai", "version": 1, "targetGroup": "AI"}}
		data, _ = json.Marshal(source)
		if err = os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return version
	}
	publish := func(current configpipeline.Version, previous *configpipeline.Version) {
		if err := store.Commit(context.Background(), configpipeline.Snapshot{Current: &current, Previous: previous, Profiles: map[string]configpipeline.Version{current.ProfileID: current}}); err != nil {
			t.Fatal(err)
		}
	}
	a := "proxies: [{name: one, type: direct}]\nproxy-groups: [{name: AI, type: select, proxies: [one]}]\nrules: ['MATCH,AI']\ndns: {enable: false}\n"
	first := stage("a.yaml", a)
	publish(first, nil)
	if observed() != "" {
		t.Fatal("stage/commit pretended to observe runtime apply")
	}
	if err := coreStartTun(0, a, `{"mixedPort":0}`); err == nil || observed() != "" {
		t.Fatal("rejected native start changed observed identity")
	}
	if status := reload(a, ""); status != 401 || observed() != "" {
		t.Fatal("unauthenticated request changed observation", status)
	}
	if status := reload(a, "Bearer "+controllerSecret); status != http.StatusNoContent || observed() != digest(a) {
		t.Fatal("actual reload did not notify observer", status)
	}
	tunListener = &sing_tun.Listener{}
	if _, err := activeAIProbeIdentity(first.ID); err != nil {
		t.Fatal("actual applied version not recognized", err)
	}
	priorIdentity, err := activeAIProbeIdentity(first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if status := reload(a, "Bearer "+controllerSecret); status != http.StatusNoContent {
		t.Fatal("identical successful reload rejected", status)
	}
	nextIdentity, err := activeAIProbeIdentity(first.ID)
	if err != nil || priorIdentity.Runtime == nextIdentity.Runtime || priorIdentity.Selection == nextIdentity.Selection {
		t.Fatal("same-text runtime replacement retained old probe lease", err)
	}
	if status := reload("proxy-groups: [", "Bearer "+controllerSecret); status != 400 || observed() != digest(a) {
		t.Fatal("rejected reload overwrote applied identity", status)
	}
	b := a + "# next synthetic profile\n"
	second := stage("b.yaml", b)
	if status := reload(b, "Bearer "+controllerSecret); status != http.StatusNoContent || observed() != digest(b) {
		t.Fatal("switch did not invalidate old applied digest", status)
	}
	if _, err := activeAIProbeIdentity(first.ID); err == nil {
		t.Fatal("reload-to-commit window admitted old revision")
	}
	publish(second, &first)
	if _, err := activeAIProbeIdentity(first.ID); err == nil {
		t.Fatal("previous profile remained current")
	}
	if id, err := activeAIProbeIdentity(second.ID); err != nil || id.Profile != "b.yaml" {
		t.Fatal("new published and applied profile not recognized", err)
	}
}
