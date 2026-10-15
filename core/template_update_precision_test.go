package main

import "testing"

func TestTemplateTransportRefusesInexactNumbersWithoutTouchingText(t *testing.T) {
	for _, value := range []string{`{"value":9007199254740993}`, `{"nested":[18446744073709551615]}`, `{"number":1.0000000000000001}`} {
		if safeTemplateJSON([]byte(value)) {
			t.Fatal("inexact number admitted")
		}
	}
	for _, value := range []string{`{"value":9007199254740992}`, `{"value":0.1}`, `{"private":"9007199254740993"}`, `{"value":1081}`} {
		if !safeTemplateJSON([]byte(value)) {
			t.Fatal("exact numeric/text transport rejected")
		}
	}
}
