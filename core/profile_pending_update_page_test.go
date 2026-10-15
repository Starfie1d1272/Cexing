package main

import "testing"

func TestPendingUpdateActualProfilePageResumesWithoutDownload(t *testing.T) {
	runCandidateDraftFixture(t, "../scripts/ci/profile-pending-update-page.cjs", []string{
		"save", "cold-reopen", "cold-apply", "consumed", "template-save", "profile-resume-update",
	})
}
