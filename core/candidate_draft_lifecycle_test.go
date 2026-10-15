package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

// Runs actual ArkTS host/transaction/store modules against the real Go dispatcher.
// Platform file APIs are backed by a temporary filesystem; no listeners or fetch.
func TestCandidateDraftLifecycleActualHostAndCompiler(t *testing.T) {
	phases := []string{"save", "cold-reopen", "cold-apply", "consumed", "template-save", "template-reopen", "template-apply"}
	// #211 supplies the actual rule page fixture. Its combined tree must run
	// all four stages through this same real worker, not a temporary hook.
	if _, err := os.Stat("../scripts/ci/candidate-rule-page-lifecycle.cjs"); err == nil {
		phases = append(phases, "rules-save", "rules-reopen", "rules-modify", "rules-apply")
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
	runCandidateDraftFixture(t, "../scripts/ci/candidate-draft-lifecycle.cjs", phases)
}

func TestPairedEditSourceActualReader(t *testing.T) {
	runCandidateDraftFixture(t, "../scripts/ci/paired-edit-source.cjs", []string{"seed", "read-source"})
}

// Shared real-worker runner for page/model fixtures. Each caller is isolated
// from other Go tests; phases share files and open independent Node processes.
func runCandidateDraftFixture(t *testing.T, script string, phases []string) {
	t.Helper()
	if len(phases) == 0 {
		t.Fatal("candidate fixture requires phases")
	}
	if _, e := exec.LookPath("node"); e != nil {
		t.Skip("Node required for ArkTS integration")
	}
	if _, e := os.Stat("../scripts/ci/node_modules/typescript"); e != nil {
		t.Skip("scripts/ci dependencies required for ArkTS integration")
	}
	// Region validation may initialize LightGBM's process-wide sync.Once with a
	// missing-model fixture. Keep every dispatcher call in a separate Go
	// process so later real-model forwarding gates start with untouched state.
	if os.Getenv("CEXING_CANDIDATE_DRAFT_CHILD") != "1" {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^"+regexp.QuoteMeta(t.Name())+"$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_CANDIDATE_DRAFT_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("candidate lifecycle child: %v\n%s", err, out)
		}
		t.Logf("real candidate fixture stages passed: %v", phases)
		return
	}
	home := t.TempDir()
	if e := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); e != nil {
		t.Fatal(e)
	}
	for _, phase := range phases {
		ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "node", script, home, phase)
		input, e := cmd.StdinPipe()
		if e != nil {
			t.Fatal(e)
		}
		output, e := cmd.StdoutPipe()
		if e != nil {
			t.Fatal(e)
		}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if e = cmd.Start(); e != nil {
			t.Fatal(e)
		}
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 64*1024), 100*1024*1024)
		for scanner.Scan() {
			var request struct {
				ID    int    `json:"id"`
				Input string `json:"input"`
			}
			if json.Unmarshal(scanner.Bytes(), &request) != nil || request.ID == 0 {
				continue
			}
			reply := coreVersionAction(home, request.Input)
			if e = json.NewEncoder(input).Encode(map[string]any{"id": request.ID, "reply": reply}); e != nil {
				t.Fatal(e)
			}
		}
		input.Close()
		if e = cmd.Wait(); e != nil {
			t.Fatalf("%s: %v\n%s", phase, e, stderr.String())
		}
		if e = scanner.Err(); e != nil {
			t.Fatal(e)
		}
	}
}
