package main

import (
	"os"
	"path/filepath"
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
		{CountryCode: "OTHER", Domain: []*router.Domain{{Type: router.Domain_Regex, Value: "test.*", Attribute: []*router.Domain_Attribute{{Key: "cn", TypedValue: &router.Domain_Attribute_BoolValue{BoolValue: true}}}}}},
	}}
	data, err := proto.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(in, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifest, []byte(`{"BILIINTL":["b.test"],"SHAREPOINT":["s.test"]}`), 0600); err != nil {
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
	if !proto.Equal(got.Entry[2], original.Entry[2]) {
		t.Fatal("unrelated category changed")
	}
	for i, want := range []string{"b.test", "s.test"} {
		if len(got.Entry[i].Domain) != 1 || got.Entry[i].Domain[0].Type != router.Domain_Domain || got.Entry[i].Domain[0].Value != want {
			t.Fatalf("wrong replacement: %v", got.Entry[i])
		}
	}
}
