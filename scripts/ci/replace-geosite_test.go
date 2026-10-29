package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func TestReplaceCategoriesPreservesOtherEntries(t *testing.T) {
	dir := t.TempDir()
	in, manifest, out := filepath.Join(dir, "in"), filepath.Join(dir, "manifest"), filepath.Join(dir, "out")
	original := &router.GeoSiteList{Entry: []*router.GeoSite{
		{CountryCode: "BILIINTL", Domain: []*router.Domain{{Type: router.Domain_Full, Value: "old.test"}}},
		{CountryCode: "SHAREPOINT", Domain: []*router.Domain{{Value: "old.test"}}},
		{CountryCode: "HTTPDNS"},
		{CountryCode: "OTHER", Domain: []*router.Domain{{Type: router.Domain_Regex, Value: "test.*", Attribute: []*router.Domain_Attribute{{Key: "cn", TypedValue: &router.Domain_Attribute_BoolValue{BoolValue: true}}}}}},
	}}
	data, err := proto.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(in, data, 0600); err != nil {
		t.Fatal(err)
	}
	var entries []string
	var source strings.Builder
	for i := 0; i < 22; i++ {
		name := fmt.Sprintf("host%d.test", i)
		entries = append(entries, "full:"+name)
		source.WriteString("DOMAIN," + name + "\n")
	}
	if err := os.Mkdir(filepath.Join(dir, "sources"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sources", "HTTPDNS.Block.list"), []byte(source.String()), 0600); err != nil {
		t.Fatal(err)
	}
	manifestJSON, err := json.Marshal(map[string][]string{"BILIINTL": {"b.test"}, "SHAREPOINT": {"s.test"}, "HTTPDNS": entries})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifest, manifestJSON, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(in, manifest, out); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var got router.GeoSiteList
	if err := proto.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(got.Entry[3], original.Entry[3]) {
		t.Fatal("unrelated category changed")
	}
	for i, want := range []string{"b.test", "s.test"} {
		if len(got.Entry[i].Domain) != 1 || got.Entry[i].Domain[0].Type != router.Domain_Domain || got.Entry[i].Domain[0].Value != want {
			t.Fatalf("wrong replacement: %v", got.Entry[i])
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "sources", "HTTPDNS.Block.list"), []byte("DOMAIN,unrelated.test\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(in, manifest, out); err == nil {
		t.Fatal("HTTPDNS entry without upstream evidence accepted")
	}
}
