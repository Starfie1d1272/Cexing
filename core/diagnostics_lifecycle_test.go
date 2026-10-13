package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The producer source contract is checked by test-diagnostic-vocabulary.cjs;
// this fixture exercises actual privacy filtering and on-disk journal fields.
func TestDiagnosticLifecycleFieldsSurvivePersistence(t *testing.T) {
	s, err := newDiagnosticStore(t.TempDir(), "host")
	if err != nil {
		t.Fatal(err)
	}
	stages := strings.Fields("native_evidence recovery_probe recovery_binding recovery_validation runtime_validation start_precondition service_binding kernel_readiness stop tun_create protect geodata_prepare smart_model_prepare panel_assets_prepare core_initialize configuration_prepare core_start tun_destroy late_tun_destroy core_stop")
	reasons := strings.Fields("extension_event_via_ipc snapshot_missing_at_stop_return retired_request_not_collected native_snapshot_not_collected")
	codes := strings.Fields("NATIVE_STOP_SNAPSHOT_PENDING NATIVE_EVIDENCE_SUPERSEDED NATIVE_EVIDENCE_SCOPE_MISMATCH NATIVE_EVENTS_TRUNCATED NATIVE_EVENT_INVALID NATIVE_EVENTS_UNAVAILABLE CONTROLLER_PROBE_UNCONFIRMED VPN_SESSION_UNCONFIRMED SERVICE_BIND_FAILED STOP_NOT_CONFIRMED START_SUPERSEDED AUTHORIZATION_FAILED OPTIONAL_MODEL_UNAVAILABLE OPTIONAL_PANEL_UNAVAILABLE TUN_CREATE_FAILED PROTECT_FAILED GEODATA_PREPARE_FAILED SMART_MODEL_PREPARE_FAILED PANEL_ASSETS_PREPARE_FAILED CORE_INITIALIZE_FAILED CONFIGURATION_PREPARE_FAILED CORE_START_FAILED TUN_DESTROY_FAILED LATE_TUN_DESTROY_FAILED CORE_STOP_FAILED 201 -2147483648 4294967295")
	for i, stage := range stages {
		reason := reasons[i%len(reasons)]
		code := codes[i%len(codes)]
		if err := s.record(diagnosticEvent{Operation: "vpn", Stage: stage, Outcome: "unknown", Reason: reason, Object: "synthetic-vpn-session", Error: s.hostCode(code)}); err != nil {
			t.Fatal(err)
		}
	}
	for _, code := range codes {
		if err := s.record(diagnosticEvent{Operation: "vpn", Stage: "native_evidence", Outcome: "failed", Error: s.hostCode(code)}); err != nil {
			t.Fatal(err)
		}
	}
	source := readDiagnosticSource(s.root, "host-current")
	if source.Status != "available" {
		t.Fatal(source.Status)
	}
	for i, e := range source.Journal.Events {
		if e.Operation != "vpn" || e.Stage == "unknown" || e.Error.Code == "unknown" || e.Error.CodeIdentity != "" {
			t.Fatalf("legitimate lifecycle field was lost: %+v", e)
		}
		if i < len(stages) && (e.Stage != stages[i] || e.Reason != reasons[i%len(reasons)]) {
			t.Fatalf("stage/reason changed: %+v", e)
		}
	}
	// Adding finite caller constants must not admit arbitrary identifier-like values.
	if err := s.record(diagnosticEvent{Operation: "vpn", Stage: "synthetic_private_identifier", Outcome: "failed", Reason: "synthetic_private_reason", Error: s.hostCode("SYNTHETIC_PRIVATE_TOKEN")}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(s.root, "host-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"synthetic_private_identifier", "synthetic_private_reason", "SYNTHETIC_PRIVATE_TOKEN", "synthetic-vpn-session"} {
		if strings.Contains(string(data), raw) {
			t.Fatalf("unapproved plaintext persisted: %s", raw)
		}
	}
}
