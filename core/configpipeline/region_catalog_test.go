package configpipeline

import (
	"context"
	"gopkg.in/yaml.v3"
	"strings"
	"testing"
)

func TestRegionCatalogueNamesCodesAndFlags(t *testing.T) {
	cases := map[string]string{
		"HK01": "香港", "HKG-2": "香港", "🇭🇰 香港": "香港", "JP2 Tokyo": "日本", "🇯🇵Japan": "日本",
		"🇸🇬SG-1": "新加坡", "USA2": "美国", "🇰🇷 韩国": "韩国", "UK-2 London": "英国",
		"🇨🇦Canada": "加拿大", "加拿大2": "加拿大", "CAN-03": "加拿大", "🇫🇷France": "法国", "FRA01": "法国",
		"🇦🇺Australia": "澳大利亚", "AU1": "澳大利亚", "🇳🇱Netherlands": "荷兰", "NLD2": "荷兰",
		"🇮🇳India": "印度", "IND-2": "印度", "🇧🇷Brazil": "巴西", "🇿🇦South Africa": "南非",
		"🇷🇺俄罗斯": "俄罗斯", "Russia": "俄罗斯", "🇹🇭泰國": "泰国", "🇹🇷Türkiye": "土耳其",
		"普通节点": "未知", "USEast": "未知", "in test": "未知", "Italy Hong Kong": "未知", "🇯🇵🇺🇸": "未知",
	}
	for name, want := range cases {
		if got := guessRegion(name); got != want {
			t.Errorf("%q: got %q want %q", name, got, want)
		}
	}
	if len(regionNames()) < 240 {
		t.Fatal("country catalogue incomplete")
	}
	for _, name := range regionNames() {
		if !validRegion(name) {
			t.Fatalf("invalid catalogue region %q", name)
		}
	}
}

func TestRegionCompactNamesReferencesAndLegacyPlan(t *testing.T) {
	original := []byte(regionFixture)
	for _, mode := range []string{"region", "all"} {
		root, err := RegionMergedSource(original, nil)
		if err != nil {
			t.Fatal(err)
		}
		// The persisted plan format and entry ID remain unchanged across upgrades.
		plan := RegionPlan{Mode: mode, Selector: "Main", Enable: true, Assignments: map[string]string{"mystery": "未知"}}
		if err = ApplyRegion(context.Background(), root, plan); err != nil {
			t.Fatal(err)
		}
		if err = validateReferences(root); err != nil {
			t.Fatal(err)
		}
		got, _ := yaml.Marshal(root)
		text := string(got)
		if !strings.Contains(text, "MATCH,Main") || !strings.Contains(text, "Cexing Smart Main") {
			t.Fatal("original references or stable entry lost")
		}
		for _, name := range []string{"香港 · Smart", "日本 · Smart", "其他地区 · Smart"} {
			if mode == "region" && !strings.Contains(text, name) {
				t.Errorf("missing %q", name)
			}
		}
		if mode == "all" && !strings.Contains(text, "全部节点 · Smart") {
			t.Fatal("all-node name not compact")
		}
		if strings.Contains(text, "Cexing Smart Main 香港") {
			t.Fatal("old verbose child name")
		}
	}
	// Collision fails closed; a user's group is never renamed or replaced.
	root, _ := RegionMergedSource(original, []byte("proxy-groups:\n - {name: Main, type: select, proxies: [HK Alpha, JP Beta, mystery]}\n - {name: '香港 · Smart', type: select, proxies: [DIRECT]}\n"))
	if err := ApplyRegion(context.Background(), root, RegionPlan{Mode: "region", Selector: "Main"}); err == nil {
		t.Fatal("collision accepted")
	}
	// Newly supported assignments are honored and unknown remains a supported saved value.
	root, _ = RegionMergedSource(original, nil)
	preview, err := PreviewRegion(root, "Main", map[string]string{"mystery": "加拿大"})
	if err != nil || preview.Nodes["mystery"] != "加拿大" || len(preview.Regions) < 240 {
		t.Fatalf("manual assignment/catalogue mismatch: %+v %v", preview, err)
	}
}
