package configpipeline

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTemplateProvenanceStrictSchema(t *testing.T) {
	valid := `{"schemaVersion":1,"revision":"draft","sourceRevision":"source","operations":[],"template":{"templateId":"ai","version":1,"targetGroup":"AI","baseline":{"templateId":"ai","version":1,"entries":[{"id":"ai/web","section":"rules","value":"DOMAIN,synthetic,AI"}]},"mine":{"templateId":"ai","version":1,"entries":[],"deleted":["ai/web"]}}}`
	if _, err := DecodeEditIntent([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		strings.Replace(valid, `"mine":{`, `"unknown":true,"mine":{`, 1),
		strings.Replace(valid, `"deleted":["ai/web"]`, `"deleted":["ai/web","ai/web"]`, 1),
		strings.Replace(valid, `"section":"rules"`, `"section":"external-controller"`, 1),
		strings.Replace(valid, `"id":"ai/web"`, `"id":"../private"`, 1),
		strings.Replace(valid, `"templateId":"ai","version":1,"entries":[]`, `"templateId":"region","version":1,"entries":[]`, 1),
		strings.Replace(valid, `"value":"DOMAIN,synthetic,AI"`, `"value":{"secret":"private"}`, 1),
		strings.Replace(valid, `"value":"DOMAIN,synthetic,AI"`, `"value":{"duplicate":1,"duplicate":2}`, 1),
	} {
		if _, err := DecodeEditIntent([]byte(bad)); err == nil {
			t.Fatal("invalid provenance admitted", bad)
		}
	}
	var intent EditIntent
	_ = json.Unmarshal([]byte(valid), &intent)
	intent.Template.Mine = nil
	if CheckEditIntent(&intent) == nil {
		t.Fatal("unpaired baseline admitted")
	}
}
