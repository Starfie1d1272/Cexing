package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTemplateUpdateWorkerIsBoundedAndInert(t *testing.T) {
	input := `{"op":"template-update-preview","request":{"kind":"template","base":{"templateId":"ai","version":1,"entries":[{"id":"ai/web","section":"rules","value":"DOMAIN,synthetic.example,AI"}]},"mine":{"templateId":"ai","version":1,"entries":[]},"next":{"templateId":"ai","version":2,"entries":[{"id":"ai/web","section":"rules","value":"DOMAIN,synthetic.example,AI"}]}}}`
	var result struct {
		Ready     bool
		Candidate struct {
			Entries []any
			Deleted []string
		}
	}
	if err := json.Unmarshal([]byte(coreTemplateUpdateAction(input)), &result); err != nil || !result.Ready || len(result.Candidate.Entries) != 0 || len(result.Candidate.Deleted) != 1 {
		t.Fatal("worker lost deletion", err)
	}
	for _, bad := range []string{input + "{}", strings.Replace(input, `"op":`, `"unexpected":true,"op":`, 1), strings.Repeat("x", 4*1024*1024+1)} {
		output := coreTemplateUpdateAction(bad)
		if !strings.Contains(output, `"error"`) || strings.Contains(output, "synthetic.example") {
			t.Fatal("unsafe error", output)
		}
	}
}
