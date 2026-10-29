package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func TestMergePreservesOtherCategoriesAndRejectsMissingInput(t *testing.T) {
	dir := t.TempDir()
	base := filepath.Join(dir, "base")
	generated := filepath.Join(dir, "new")
	out := filepath.Join(dir, "out")
	names := strings.Fields("CN STEAM ONEDRIVE MICROSOFT CATEGORY-NETDISK-!CN CATEGORY-GAMES-!CN CATEGORY-GAMES CATEGORY-ENTERTAINMENT CATEGORY-COMPANIES CATEGORY-ADS CATEGORY-ADS-ALL CATEGORY-ADS-AND-TELEMETRY CATEGORY-TELEMETRY GEOLOCATION-!CN TRACKER GFW GOOGLE-CN APPLE-CN")
	before := &router.GeoSiteList{}
	after := &router.GeoSiteList{}
	for _, name := range names {
		before.Entry = append(before.Entry, &router.GeoSite{CountryCode: name, Domain: []*router.Domain{{Type: router.Domain_Full, Value: "old.test"}}})
		after.Entry = append(after.Entry, &router.GeoSite{CountryCode: name, Domain: []*router.Domain{{Type: router.Domain_Domain, Value: "new.test"}}})
	}
	before.Entry = append(before.Entry, &router.GeoSite{CountryCode: "OTHER", Domain: []*router.Domain{{Type: router.Domain_Regex, Value: "other.*"}}})
	write := func(path string, list *router.GeoSiteList) {
		t.Helper()
		b, e := proto.Marshal(list)
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(path, b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	write(base, before)
	write(generated, after)
	if err := run(base, generated, out); err != nil {
		t.Fatal(err)
	}
	got, err := load(out)
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(got.Entry[len(names)], before.Entry[len(names)]) {
		t.Fatal("unrelated category changed")
	}
	if !proto.Equal(got.Entry[0], after.Entry[0]) {
		t.Fatal("replacement not applied")
	}
	after.Entry = after.Entry[1:]
	write(generated, after)
	if err := run(base, generated, out); err == nil {
		t.Fatal("missing category accepted")
	}
}
