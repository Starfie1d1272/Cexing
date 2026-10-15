package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Runs actual ArkTS host/transaction/store modules against the real Go dispatcher.
// Platform file APIs are backed by a temporary filesystem; no listeners or fetch.
func TestCandidateDraftLifecycleActualHostAndCompiler(t *testing.T) {
	if _, e := exec.LookPath("node"); e != nil {
		t.Skip("Node required for ArkTS integration")
	}
	if _, e := os.Stat("../scripts/ci/node_modules/typescript"); e != nil {
		t.Skip("scripts/ci dependencies required for ArkTS integration")
	}
	home := t.TempDir()
	if e := os.WriteFile(filepath.Join(home, "geoip.metadb"), []byte("synthetic"), 0600); e != nil {
		t.Fatal(e)
	}
	for _, phase := range []string{"save", "cold-reopen", "cold-apply", "consumed", "template-save", "template-reopen", "template-apply"} {
		ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "node", "../scripts/ci/candidate-draft-lifecycle.cjs", home, phase)
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
