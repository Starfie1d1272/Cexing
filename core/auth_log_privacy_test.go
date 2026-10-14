package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestAuthenticationLogPrivacy(t *testing.T) {
	home := t.TempDir()
	s, err := getDiagnosticStore(home, "kernel")
	if err != nil {
		t.Fatal(err)
	}
	user, password := "SyntheticBasicUser", "SyntheticBasicPassword"
	encoded := base64.StdEncoding.EncodeToString([]byte(user + ":" + password))
	s.registerPrivateConfig(map[string]any{"username": user, "password": password})
	oldHome := diagnosticKernelDirectory()
	diagnosticKernelHome.Store(home)
	defer diagnosticKernelHome.Store(oldHome)
	cases := map[string]string{
		"authorization-basic":  "Authorization: Basic " + encoded,
		"proxy-basic":          "pRoXy-AuThOrIzAtIoN = Basic\t" + encoded,
		"json-key":             `{"Authorization":"Basic ` + encoded + `"}`,
		"header-map":           "map[Proxy-Authorization:[Basic " + encoded + "] Other:[ok]]",
		"folded":               "Authorization: Basic\r\n\t" + encoded + "\r\n\tSyntheticContinuation",
		"bearer":               "Authorization: Bearer " + encoded,
		"negotiate":            "Authorization: Negotiate " + encoded,
		"ntlm":                 "Proxy-Authorization: NTLM " + encoded,
		"digest":               fmt.Sprintf(`Authorization: Digest username="%s", realm="SyntheticRealm", nonce="SyntheticNonce", response=%s`, user, encoded),
		"unknown-scheme":       "Authorization: SyntheticScheme opaque=" + encoded + ", another=SyntheticParameter",
		"standalone-digest":    `request rejected Digest username="` + user + `", nonce="SyntheticNonce", response=` + encoded,
		"standalone-basic":     "request rejected Basic " + encoded,
		"standalone-negotiate": "request rejected Negotiate " + encoded,
		"standalone-ntlm":      "request rejected NTLM " + encoded,
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			for _, output := range []string{s.text(input), redactOrdinaryLog(input)} {
				for _, value := range []string{user, password, encoded, "SyntheticRealm", "SyntheticNonce", "SyntheticParameter", "SyntheticContinuation"} {
					if strings.Contains(output, value) {
						t.Fatal("authentication material survived redaction")
					}
				}
				if output == "" {
					t.Fatal("redaction discarded the entire event")
				}
			}
		})
	}
	if !strings.Contains(s.text("Authorization: Basic "+encoded+"\r\nNEXT_PUBLIC_EVENT"), "NEXT_PUBLIC_EVENT") {
		t.Fatal("authentication redaction consumed the next independent line")
	}
	kernelDiagnosticLog("warning", "[TCP] dial failed: Authorization: Basic "+encoded)
	bundle, err := diagnosticBundle(home)
	if err != nil || !json.Valid([]byte(bundle)) || !strings.Contains(bundle, "runtime_error") {
		t.Fatal("structured diagnostic export did not retain the authentication failure event")
	}
	if strings.Contains(bundle, encoded) || strings.Contains(bundle, user) || strings.Contains(bundle, password) {
		t.Fatal("authentication material survived structured diagnostic export")
	}

}
