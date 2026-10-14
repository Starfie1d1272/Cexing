package configpipeline

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func diffRoot(t *testing.T, source string) *yaml.Node {
	t.Helper()
	root, e := parse([]byte(source))
	if e != nil {
		t.Fatal(e)
	}
	return root
}
func findChange(t *testing.T, changes []Change, section string) Change {
	t.Helper()
	for _, c := range changes {
		if c.Section == section {
			return c
		}
	}
	t.Fatal("missing change", section)
	return Change{}
}
func TestSemanticSummaryEqualCountReplacementOrderAndTypes(t *testing.T) {
	old := diffRoot(t, "rules: ['DOMAIN,private-a.test,DIRECT','IP-CIDR,192.0.2.0/24,REJECT,no-resolve','MATCH,DIRECT']\n")
	replaced := diffRoot(t, "rules: ['DOMAIN,private-b.test,DIRECT','IP-CIDR,192.0.2.0/24,REJECT,no-resolve','MATCH,DIRECT']\n")
	c := findChange(t, summarizeChanges(old, replaced), "rules")
	if c.Before != 3 || c.After != 3 || c.Modified != 1 || !c.ContentChanged || c.Reordered || c.Kind != "modified" {
		t.Fatal("same-count replacement hidden", c)
	}
	reorder := diffRoot(t, "rules: ['MATCH,DIRECT','DOMAIN,private-a.test,DIRECT','IP-CIDR,192.0.2.0/24,REJECT,no-resolve']\n")
	c = findChange(t, summarizeChanges(old, reorder), "rules")
	if !c.Reordered || c.Kind != "reordered" || c.Modified != 0 {
		t.Fatal("order not identified", c)
	}
	changedType := diffRoot(t, "rules: ['DOMAIN-SUFFIX,private-a.test,DIRECT','IP-CIDR,192.0.2.0/24,REJECT,no-resolve','MATCH,DIRECT']\n")
	c = findChange(t, summarizeChanges(old, changedType), "rules")
	if c.TypesChanged != 1 {
		t.Fatal("rule type change missing", c)
	}
	cleared := diffRoot(t, "rules: []\n")
	c = findChange(t, summarizeChanges(old, cleared), "rules")
	if c.Kind != "cleared" || c.Removed != 3 || c.After != 0 {
		t.Fatal("clear missing", c)
	}
}
func TestSemanticSummaryGroupsDNSHostsAndEquivalentFormatting(t *testing.T) {
	old := diffRoot(t, `proxy-groups: [{name: secret-group, type: select, proxies: [private-a,private-b]}]
dns: {nameserver: [192.0.2.53], nameserver-policy: {private-a.test: 1.1.1.1, private-b.test: 8.8.8.8}, x-private.test: secret}
hosts: {private-a.test: 192.0.2.1}
`)
	next := diffRoot(t, `proxy-groups: [{name: secret-group, type: url-test, proxies: [private-b,private-a]}]
dns: {nameserver: [198.51.100.53], nameserver-policy: {private-b.test: 8.8.8.8, private-a.test: 1.1.1.1}, x-private.test: changed-secret}
hosts: {private-a.test: 192.0.2.2}
`)
	changes := summarizeChanges(old, next)
	group := findChange(t, changes, "proxy-groups")
	if group.TypesChanged != 1 || group.MembersChanged != 1 || group.Modified != 1 {
		t.Fatal("group semantics lost", group)
	}
	dns := findChange(t, changes, "dns")
	fields := map[string]FieldChange{}
	for _, f := range dns.Fields {
		fields[f.Field] = f
	}
	if fields["nameserver"].Kind != "modified" || !fields["nameserver-policy"].Reordered || fields["advanced"].Kind != "modified" {
		t.Fatal("DNS exceptions/order hidden", dns)
	}
	hosts := findChange(t, changes, "hosts")
	if hosts.Modified != 1 || hosts.Before != hosts.After {
		t.Fatal("hosts replacement hidden", hosts)
	}
	formatted := diffRoot(t, `hosts: {private-a.test: 192.0.2.1}
dns:
 x-private.test: secret
 nameserver-policy: {private-a.test: 1.1.1.1, private-b.test: 8.8.8.8}
 nameserver: [192.0.2.53]
proxy-groups: [{proxies: [private-a,private-b], type: select, name: secret-group}]
`)
	if changes := summarizeChanges(old, formatted); len(changes) != 0 {
		t.Fatal("equivalent formatting reported", changes)
	}
	b, _ := json.Marshal(changes)
	for _, private := range []string{"private-", "secret-group", "192.0.2", "198.51.100", "changed-secret", "x-private"} {
		if strings.Contains(string(b), private) {
			t.Fatal("summary leaks private value/key", private)
		}
	}
}
func TestSemanticPreviewPlatformAttemptsWithoutPolicyDuplication(t *testing.T) {
	original := []byte("proxies: [{name: private-node, type: direct}]\nrules: ['MATCH,DIRECT']\ndns: {enable: true}\n")
	project := func(_ context.Context, root *yaml.Node) error {
		set(root, "external-controller", scalar("127.0.0.1:9090"))
		set(root, "listeners", &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"})
		set(field(root, "dns"), "listen", scalar("127.0.0.1:1053"))
		return nil
	}
	c := Compiler{Platform: project, Validate: func(context.Context, []byte) error { return nil }}
	overlay := []byte("external-controller: private-controller.test:9999\nlisteners: [{name: private-listener, type: mixed, port: 9999}]\ndns: {listen: '0.0.0.0:53'}\n")
	r, e := c.Compile(context.Background(), Request{Original: original, Overlays: [][]byte{overlay}, Previous: original})
	if e != nil {
		t.Fatal(e)
	}
	if len(r.PlatformChanges) != 3 {
		t.Fatal("overridden fields not exposed", r.PlatformChanges)
	}
	for _, change := range r.PlatformChanges {
		if change.Kind != "protected" {
			t.Fatal("projection classification", change)
		}
	}
	b, _ := json.Marshal(r.PlatformChanges)
	if strings.Contains(string(b), "private-") || strings.Contains(string(b), "0.0.0.0") || strings.Contains(string(b), "9999") {
		t.Fatal("projection value leak")
	}
	unchanged, e := c.Compile(context.Background(), Request{Original: original, Previous: original})
	if e != nil || len(unchanged.PlatformChanges) != 0 {
		t.Fatal("injected host defaults misreported as ignored input", e, unchanged.PlatformChanges)
	}
	if string(r.Original) != string(original) {
		t.Fatal("preview changed original")
	}
}
