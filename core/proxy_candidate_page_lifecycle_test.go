package main

import "testing"

func TestProxyCandidateActualPageAndReceipt(t *testing.T) {
	runCandidateDraftFixture(t, "../scripts/ci/candidate-proxy-page-lifecycle.cjs", []string{
		"proxy-save", "proxy-reopen", "proxy-modify", "proxy-apply",
	})
}
