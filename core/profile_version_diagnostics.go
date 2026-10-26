package main

// Only a fixed operation and closed error code reach the existing local journal.
// No source, file name, metadata, URL or arbitrary exception is recorded.
func recordProfileVersionFailure(home, operation, code string) {
	stage := "configuration_prepare"
	if operation == "commit" {
		stage = "config_apply"
	}
	store, err := getDiagnosticStore(home, "host")
	if err != nil {
		return
	}
	_ = store.record(diagnosticEvent{Operation: "profile", Stage: stage, Outcome: "failed", Error: store.hostCode(code)})
}
