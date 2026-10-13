package configpipeline

import (
	"regexp"
	"sort"
	"strings"

	"golang.org/x/text/language"
	"golang.org/x/text/language/display"
)

// CLDR names and ISO codes come from the already pinned x/text module.
// Name inference is a suggestion; conflicting signals remain unassigned.
var regionPatterns = makeRegionPatterns()

type regionPattern struct {
	code string
	re   *regexp.Regexp
}

func makeRegionPatterns() []regionPattern {
	chinese := display.Regions(language.SimplifiedChinese)
	traditional := display.Regions(language.TraditionalChinese)
	english := display.Regions(language.English)
	short := map[string]string{"HK": "香港", "TW": "台湾"}
	aliases := map[string]string{
		"HK": `香港|港[区線线]|Hong[ -]?Kong`,
		"TW": `台湾|臺灣|台[区線线]`,
		"JP": `日本|日[区線线]|(?i:\bTokyo\b|\bOsaka\b)`,
		"SG": `新加坡|狮城|獅城`,
		"US": `美国|美國|美[区線线]`,
		"KR": `韩国|韓國`,
		"GB": `英国|英國|(?:^|[^A-Za-z])UK(?:[^A-Za-z]|$)|(?i:\bBritain\b|\bLondon\b)`,
		"DE": `德国|德國`,
	}
	out := []regionPattern{}
	for a := 'A'; a <= 'Z'; a++ {
		for b := 'A'; b <= 'Z'; b++ {
			iso := string([]rune{a, b})
			r, err := language.ParseRegion(iso)
			if err != nil || !r.IsCountry() || r.Canonicalize() != r {
				continue
			}
			name := chinese.Name(r)
			if name == "" || english.Name(r) == "" {
				continue
			}
			if label, ok := short[iso]; ok {
				name = label
			}
			flag := string([]rune{0x1f1e6 + a - 'A', 0x1f1e6 + b - 'A'})
			// Codes may touch digits (HK01/USA2), never another Latin letter.
			// Uppercase codes avoid interpreting everyday words such as "in".
			codes := iso
			if three := r.ISO3(); three != "" && three != iso {
				codes += "|" + three
			}
			pattern := `(?:^|[^A-Za-z])(?:` + codes + `)(?:[^A-Za-z]|$)|` + flag
			for _, label := range []string{chinese.Name(r), traditional.Name(r)} {
				if label != "" && label != iso {
					pattern += "|" + regexp.QuoteMeta(label)
				}
			}
			en := regexp.QuoteMeta(english.Name(r))
			en = strings.ReplaceAll(en, " ", `[ -]`)
			pattern += `|(?i:(?:^|[^A-Za-z])` + en + `(?:[^A-Za-z]|$))`
			if alias, ok := aliases[iso]; ok {
				pattern += "|" + alias
			}
			out = append(out, regionPattern{name, regexp.MustCompile(pattern)})
		}
	}
	return out
}

func regionNames() []string {
	names := []string{"香港", "台湾", "日本", "新加坡", "美国", "韩国", "英国", "德国"}
	used := map[string]bool{}
	for _, name := range names {
		used[name] = true
	}
	rest := []string{}
	for _, p := range regionPatterns {
		if !used[p.code] {
			rest = append(rest, p.code)
			used[p.code] = true
		}
	}
	sort.Strings(rest)
	return append(append(names, rest...), "未知")
}

func regionLabel(code string) string {
	if code == "未知" {
		return "其他地区"
	}
	return code
}

func guessRegion(name string) string {
	match := ""
	for _, p := range regionPatterns {
		if p.re.MatchString(name) {
			if match != "" && match != p.code {
				return "未知"
			}
			match = p.code
		}
	}
	if match == "" {
		return "未知"
	}
	return match
}
