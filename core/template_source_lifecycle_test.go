package main

import "testing"

func TestTemplatePairedSourceActualReaderAndReceipt(t *testing.T) {
	runCandidateDraftFixture(t, "../scripts/ci/candidate-template-source-lifecycle.cjs", []string{
		"save", "cold-reopen", "cold-apply", "consumed", "template-save",
		"paired-source-read", "paired-source-cancel", "paired-source-page-reopen", "paired-source-page-apply",
	})
}
