package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
)

func TestDiagnosticFailedReloadKeepsRunningAndDelayedValuesPrivateOnDisk(t *testing.T) {
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	seedSyntheticPanel(t, home)
	oldName, oldPassword := "OldPrivateNodeFixture", "OldPrivatePasswordFixture"
	original := fmt.Sprintf("mixed-port: 0\nmode: direct\nproxies:\n  - {name: %s, type: ss, server: 127.0.0.1, port: 12345, cipher: aes-128-gcm, password: %s}\nrules: ['MATCH,DIRECT']\n", oldName, oldPassword)
	diagnosticRecordConfig(original, `{"mixedPort":0}`)
	cfg, err := preparePlatformConfig(original, `{"mixedPort":0}`)
	if err != nil {
		t.Fatal(err)
	}
	if err = startController(); err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	activeOverrides = `{"mixedPort":0}`
	candidate := `mixed-port: not-a-port
proxies:
  - {name: CandidatePrivateNodeFixture, type: ss, server: 127.0.0.1, password: CandidatePrivatePasswordFixture}
`
	body, _ := json.Marshal(map[string]string{"payload": candidate})
	req, err := http.NewRequest(http.MethodPut, "http://"+defaultController+"/configs", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+controllerSecret)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 400 || tunnel.Proxies()[oldName] == nil {
		t.Fatal("candidate unexpectedly replaced running config")
	}
	kernelDiagnosticLog("warning", "[TCP] dial "+oldName+" error: dial tcp: connection refused; "+oldPassword)
	kernelDiagnosticLog("warning", "[TCP] dial CandidatePrivateNodeFixture error: connection refused CandidatePrivatePasswordFixture")
	// A later successful generation still cannot erase a delayed old error's dictionary.
	replacement := `mixed-port: 0
mode: direct
proxies:
  - {name: NextPrivateNodeFixture, type: ss, server: 127.0.0.1, port: 12345, cipher: aes-128-gcm, password: NextPrivatePasswordFixture}
`
	diagnosticRecordConfig(replacement, `{"mixedPort":0}`)
	next, err := preparePlatformConfig(replacement, `{"mixedPort":0}`)
	if err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(next, true)
	kernelDiagnosticLog("warning", "[TCP] dial "+oldName+" error: connection refused "+oldPassword)
	data, err := os.ReadFile(filepath.Join(home, "diagnostics", "kernel-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{oldName, oldPassword, "CandidatePrivateNodeFixture", "CandidatePrivatePasswordFixture", "NextPrivateNodeFixture", "NextPrivatePasswordFixture"} {
		if strings.Contains(string(data), private) {
			t.Fatal("fixture value leaked to kernel journal")
		}
	}
	if !strings.Contains(string(data), "config_reload_parse") || !strings.Contains(string(data), "connection_refused") || !strings.Contains(string(data), "object-") {
		t.Fatal("failure stage/condition/association lost")
	}
}

func TestDiagnosticArbitraryCodesAndOtherFreeStringsCannotPersistPlaintext(t *testing.T) {
	home := t.TempDir()
	private := "SyntheticOpaqueCredentialFixture"
	request := map[string]any{"op": "diagnostics-record", "operation": private, "stage": private, "outcome": private, "reason": private, "object": private, "code": private,
		"environment":  map[string]any{"appVersion": private, "osVersion": private, "abi": private, "deviceType": private, "networkType": private, "versionCode": private, "sdkVersion": private},
		"settings":     map[string]any{"allowLan": private, "mixedPort": private, "mode": private, "logLevel": private, "accessMode": private},
		"observations": map[string]any{"vpnState": private, "stopOutcome": private, "failureCategory": private, "substageCoverage": private, "tunCreateObserved": private}}
	body, _ := json.Marshal(request)
	if result := coreDiagnosticAction(home, string(body)); result != `{"recorded":true}` {
		t.Fatal(result)
	}
	data, err := os.ReadFile(filepath.Join(home, "diagnostics", "host-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), private) {
		t.Fatal("arbitrary credential escaped through a free field")
	}
	var journal diagnosticJournal
	if json.Unmarshal(data, &journal) != nil {
		t.Fatal("invalid journal")
	}
	event := journal.Events[len(journal.Events)-1]
	s, _ := getDiagnosticStore(home, "host")
	if event.Error.Code != "unknown" || event.Error.CodeIdentity != s.object(private) || event.Stage != "unknown" || event.Details["stageIdentity"] != s.object(private) {
		t.Fatal("unknown value structure/association lost")
	}
	for _, code := range []string{"2300006", "errno:111", "DNS_RCODE_3", "deadline_exceeded"} {
		body, _ := json.Marshal(map[string]string{"op": "diagnostics-record", "operation": "vpn", "stage": "system_authorization", "outcome": "failed", "code": code})
		if result := coreDiagnosticAction(home, string(body)); result != `{"recorded":true}` {
			t.Fatal(result)
		}
	}
	data, err = os.ReadFile(filepath.Join(home, "diagnostics", "host-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, code := range []string{"2300006", "errno:111", "DNS_RCODE_3", "deadline_exceeded"} {
		if !strings.Contains(string(data), code) {
			t.Fatal("valid diagnostic code lost")
		}
	}
}

func TestDiagnosticConcurrentCandidateRegistrationDoesNotLoseOldLogSecrets(t *testing.T) {
	s, err := newDiagnosticStore(t.TempDir(), "kernel")
	if err != nil {
		t.Fatal(err)
	}
	original := map[string]any{"name": "ConcurrentPrivateOldNode", "password": "ConcurrentPrivateOldPassword"}
	s.registerPrivateConfig(original)
	var workers sync.WaitGroup
	for writer := 0; writer < 3; writer++ {
		workers.Add(1)
		go func(writer int) {
			defer workers.Done()
			for i := 0; i < 15; i++ {
				if writer == 0 {
					s.registerPrivateConfig(map[string]any{"name": fmt.Sprintf("CandidatePrivateNode-%d", i), "password": fmt.Sprintf("CandidatePrivatePassword-%d", i)})
				}
				if err := s.record(diagnosticEvent{Operation: "core", Stage: "runtime_error", Outcome: "warning", Error: s.logFailure("[TCP] dial ConcurrentPrivateOldNode error: connection refused ConcurrentPrivateOldPassword")}); err != nil {
					t.Error(err)
				}
			}
		}(writer)
	}
	workers.Wait()
	data, err := os.ReadFile(filepath.Join(s.root, "kernel-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "ConcurrentPrivateOldNode") || strings.Contains(string(data), "ConcurrentPrivateOldPassword") {
		t.Fatal("concurrent table update lost old sensitive values")
	}
	if !strings.Contains(string(data), "connection_refused") {
		t.Fatal("technical failure condition lost")
	}
}

func TestDiagnosticDictionaryExhaustionFailsClosedWithoutLosingErrno(t *testing.T) {
	s, err := newDiagnosticStore(t.TempDir(), "kernel")
	if err != nil {
		t.Fatal(err)
	}
	s.registerPrivateConfig(map[string]any{"name": "CapacityPrivateNode"})
	s.privacyMu.Lock()
	s.privateBytes = 8 * 1024 * 1024
	s.privacyMu.Unlock()
	s.registerPrivateConfig(map[string]any{"password": "CapacityPrivatePassword"})
	failure := s.failure(fmt.Errorf("CapacityPrivateNode CapacityPrivatePassword: %w", syscall.ECONNREFUSED), 0)
	if failure.Code != "errno:111" || !failure.DetailOmitted || len(failure.Causes) != 1 {
		t.Fatal("capacity fallback lost error structure")
	}
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "proxy_dial", Outcome: "failed", Error: failure}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(s.root, "kernel-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "CapacityPrivateNode") || strings.Contains(string(data), "CapacityPrivatePassword") || !strings.Contains(string(data), "errno:111") || !strings.Contains(string(data), "detailOmitted") {
		t.Fatal("unsafe/unmarked capacity fallback")
	}
}

func TestDiagnosticLegacyJournalCannotReplayPreFixFreeStrings(t *testing.T) {
	home := t.TempDir()
	s, err := getDiagnosticStore(home, "host")
	if err != nil {
		t.Fatal(err)
	}
	private := "PreFixCredentialFixture"
	legacy := diagnosticJournal{Schema: 1, Lane: "host", Session: "fixture-session", Events: []diagnosticEvent{{Operation: private, Stage: "system_authorization", Outcome: "failed", Object: private,
		Error: &diagnosticError{Kind: "host_code", Code: private, Message: "connection refused " + private, Causes: []diagnosticError{{Kind: "syscall.Errno", Code: "errno:111", Message: private}}}, Details: map[string]any{"appVersion": private, "osVersion": "HarmonyOS 7.0.0.109", "hostSettings": map[string]any{"mode": private}, "raw": private}}}}
	data, _ := json.Marshal(legacy)
	path := filepath.Join(s.root, "host-previous.json")
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	bundle, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(bundle, private) || !strings.Contains(bundle, "errno:111") || !strings.Contains(bundle, "system_authorization") || !strings.Contains(bundle, "legacySanitized") || !strings.Contains(bundle, "connection_refused") {
		t.Fatal("legacy privacy/technical salvage invalid")
	}
	original, err := os.ReadFile(path)
	if err != nil || string(original) != string(data) {
		t.Fatal("export changed original archived evidence")
	}
}

func TestDiagnosticConfigFreeEnumsAndOverridesCannotLeakOnDisk(t *testing.T) {
	home := t.TempDir()
	private := "ConfigFreeStringCredentialFixture"
	yaml := fmt.Sprintf("mode: direct\ndns:\n  enable: false\n  listen: %s\n  nameserver: ['%s://127.0.0.1']\nproxies:\n  - {name: Fixture, type: %s, server: 127.0.0.1, port: 443}\n", private, private, private)
	summary := diagnosticConfigSnapshot(home, yaml, "")
	s, err := getDiagnosticStore(home, "kernel")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "effective_config", Outcome: "projected", Details: summary}); err != nil {
		t.Fatal(err)
	}
	// Overrides also enter the dictionary before an invalid type can be reported.
	override, _ := json.Marshal(map[string]string{"mode": private})
	_ = diagnosticConfigSnapshot(home, "mode: direct\n", string(override))
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "config_parse", Outcome: "failed", Error: s.failure(fmt.Errorf("invalid mode %s", private), 0)}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(s.root, "kernel-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), private) || !strings.Contains(string(data), "effective_config") || !strings.Contains(string(data), "unknown") {
		t.Fatal("config free string escaped, or useful context lost")
	}
}
