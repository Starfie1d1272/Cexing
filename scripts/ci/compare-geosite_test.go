package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func TestReadPreservesTypesAttributesAndDuplicates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "geosite.dat")
	domain := &router.Domain{Type: router.Domain_Full, Value: "example.test", Attribute: []*router.Domain_Attribute{{Key: "cn", TypedValue: &router.Domain_Attribute_BoolValue{BoolValue: false}}}}
	data, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "TEST", Domain: []*router.Domain{domain, domain}}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got["TEST"]) != 1 {
		t.Fatalf("expected one distinct entry: %v", got)
	}
	for row, count := range got["TEST"] {
		if count != 2 || row != `{"type":"Full","value":"example.test","attributes":["{\"key\":\"cn\",\"TypedValue\":{\"BoolValue\":false}}"]}` {
			t.Fatalf("lost type, attribute or multiplicity: %s %d", row, count)
		}
	}
}

func TestReadRejectsDuplicateCategory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "geosite.dat")
	data, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "TEST"}, {CountryCode: "TEST"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := read(path); err == nil {
		t.Fatal("duplicate category accepted")
	}
}
