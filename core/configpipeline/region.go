package configpipeline

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strings"

	RC "github.com/metacubex/mihomo/rules/common"
	"gopkg.in/yaml.v3"
)

// RegionPlan is stored per subscription. Assignments are explicit user
// corrections to name-based guesses; they never describe a node's true location.
type RegionPlan struct {
	Mode        string            `json:"mode"`
	Selector    string            `json:"selector"`
	Enable      bool              `json:"enable"`
	Assignments map[string]string `json:"assignments,omitempty"`
}

type RegionPreview struct {
	Eligible        bool              `json:"eligible"`
	Offerable       bool              `json:"offerable"`
	ProviderPending bool              `json:"providerPending"`
	Selectors       []string          `json:"selectors"`
	Nodes           map[string]string `json:"nodes"`
	Counts          map[string]int    `json:"counts"`
	Unknown         int               `json:"unknown"`
}

var regionPatterns = []struct {
	code string
	re   *regexp.Regexp
}{
	{"香港", regexp.MustCompile(`(?i)(香港|港[区線线]|\bHK\b|Hong[ -]?Kong|🇭🇰)`)},
	{"台湾", regexp.MustCompile(`(?i)(台湾|臺灣|台[区線线]|\bTW\b|Taiwan|🇹🇼)`)},
	{"日本", regexp.MustCompile(`(?i)(日本|日[区線线]|\bJP\b|Japan|Tokyo|Osaka|🇯🇵)`)},
	{"新加坡", regexp.MustCompile(`(?i)(新加坡|狮城|獅城|\bSG\b|Singapore|🇸🇬)`)},
	{"美国", regexp.MustCompile(`(?i)(美国|美國|美[区線线]|\bUS\b|United[ -]?States|America|🇺🇸)`)},
	{"韩国", regexp.MustCompile(`(?i)(韩国|韓國|\bKR\b|Korea|🇰🇷)`)},
	{"英国", regexp.MustCompile(`(?i)(英国|英國|\bUK\b|Britain|London|🇬🇧)`)},
	{"德国", regexp.MustCompile(`(?i)(德国|德國|\bDE\b|Germany|🇩🇪)`)},
}

func guessRegion(name string) string {
	match := ""
	for _, p := range regionPatterns {
		if p.re.MatchString(name) {
			if match != "" {
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

// RegionMergedSource gives the preview the same original plus Merge view used
// by stage, without platform projection or opening provider URLs.
func RegionMergedSource(original, overlay []byte) (*yaml.Node, error) {
	root, err := parse(original)
	if err != nil {
		return nil, err
	}
	if err := rejectRuntimeCredential(root); err != nil {
		return nil, err
	}
	if len(overlay) > 0 {
		patch, err := parse(overlay)
		if err != nil {
			return nil, err
		}
		if err := rejectRuntimeCredential(patch); err != nil {
			return nil, err
		}
		merge(root, patch)
	}
	return root, nil
}

// PreviewRegion inspects only direct explicit proxy members. Group/relay/dialer
// references are never flattened. A provider-backed selector is pending until a
// separate provider snapshot can prove its members; it cannot be generated here.
func PreviewRegion(root *yaml.Node, selector string, assignments map[string]string) (RegionPreview, error) {
	p := RegionPreview{Selectors: []string{}, Nodes: map[string]string{}, Counts: map[string]int{}}
	groups, proxies := field(root, "proxy-groups"), field(root, "proxies")
	if groups == nil || groups.Kind != yaml.SequenceNode {
		return p, nil
	}
	if err := validateReferences(root); err != nil {
		return p, err
	}
	proxyNames := map[string]bool{}
	if proxies != nil {
		for _, n := range proxies.Content {
			proxyNames[field(n, "name").Value] = true
		}
	}
	var selected *yaml.Node
	convertible, smart := 0, 0
	for _, g := range groups.Content {
		name, kind := field(g, "name"), field(g, "type")
		if name == nil || kind == nil {
			return p, errors.New("invalid group")
		}
		if kind.Value == "select" {
			p.Selectors = append(p.Selectors, name.Value)
		}
		if kind.Value == "smart" {
			smart++
		}
		if kind.Value == "url-test" || kind.Value == "load-balance" {
			convertible++
		}
		if name.Value == selector {
			selected = g
		}
	}
	if convertible != 0 || smart != 0 {
		return p, nil
	}
	p.Offerable = true
	if selected == nil || field(selected, "type").Value != "select" {
		return p, nil
	}
	if use := field(selected, "use"); use != nil && len(use.Content) > 0 {
		p.ProviderPending = true
	}
	if all := field(selected, "include-all"); all != nil && all.Value == "true" {
		p.ProviderPending = true
	}
	if members := field(selected, "proxies"); members != nil {
		for _, n := range members.Content {
			if !proxyNames[n.Value] {
				continue
			}
			region := guessRegion(n.Value)
			if override, ok := assignments[n.Value]; ok {
				if !validRegion(override) {
					return p, errors.New("invalid region assignment")
				}
				region = override
			}
			p.Nodes[n.Value] = region
			p.Counts[region]++
			if region == "未知" {
				p.Unknown++
			}
		}
	}
	p.Eligible = !p.ProviderPending && len(p.Nodes) > 0
	return p, nil
}

func validRegion(code string) bool {
	if code == "未知" {
		return true
	}
	for _, p := range regionPatterns {
		if p.code == code {
			return true
		}
	}
	return false
}

func scalar(value string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
}
func sequence(values ...string) *yaml.Node {
	n := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, v := range values {
		n.Content = append(n.Content, scalar(v))
	}
	return n
}

// ApplyRegion adds a reversible generated strategy after Merge. The saved source
// and Merge are unchanged; disabling the plan recompiles them without this step.
func ApplyRegion(_ context.Context, root *yaml.Node, plan RegionPlan) error {
	if plan.Mode != "region" && plan.Mode != "all" {
		return errors.New("invalid region mode")
	}
	p, err := PreviewRegion(root, plan.Selector, plan.Assignments)
	if err != nil || !p.Eligible {
		return errors.New("region plan unavailable")
	}
	groups := field(root, "proxy-groups")
	used := map[string]bool{}
	for _, section := range []string{"proxies", "proxy-groups"} {
		if list := field(root, section); list != nil {
			for _, entry := range list.Content {
				used[field(entry, "name").Value] = true
			}
		}
	}
	base := "Cexing Smart " + plan.Selector
	if used[base] {
		return errors.New("generated group name collision")
	}
	newGroups := []*yaml.Node{}
	newNames := []string{}
	if plan.Mode == "all" {
		members := sortedKeys(p.Nodes)
		if len(members) < 2 {
			return errors.New("at least two nodes required")
		}
		name := base + " 全部"
		if used[name] {
			return errors.New("generated group name collision")
		}
		newGroups = append(newGroups, smartGroup(name, members))
		newNames = append(newNames, name)
	} else {
		for _, region := range []string{"香港", "台湾", "日本", "新加坡", "美国", "韩国", "英国", "德国", "未知"} {
			members := []string{}
			for node, code := range p.Nodes {
				if code == region {
					members = append(members, node)
				}
			}
			sort.Strings(members)
			if len(members) == 0 {
				continue
			}
			name := base + " " + region
			if used[name] {
				return errors.New("generated group name collision")
			}
			newGroups = append(newGroups, smartGroup(name, members))
			newNames = append(newNames, name)
		}
	}
	// The old Selector remains a manual fallback option; no existing member list
	// or manual choice is changed. Generated Smart groups fail closed when empty.
	newNames = append(newNames, plan.Selector)
	top := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	set(top, "name", scalar(base))
	set(top, "type", scalar("select"))
	set(top, "proxies", sequence(newNames...))
	groups.Content = append(groups.Content, newGroups...)
	groups.Content = append(groups.Content, top)
	if plan.Enable {
		return rewriteRuleTargets(root, plan.Selector, base)
	}
	return nil
}

func smartGroup(name string, members []string) *yaml.Node {
	g := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	set(g, "name", scalar(name))
	set(g, "type", scalar("smart"))
	set(g, "proxies", sequence(members...))
	set(g, "uselightgbm", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	set(g, "collectdata", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
	set(g, "empty-fallback", scalar("REJECT"))
	return g
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func rewriteRuleTargets(root *yaml.Node, old, replacement string) error {
	lists := []*yaml.Node{field(root, "rules")}
	if sub := field(root, "sub-rules"); sub != nil {
		for i := 1; i < len(sub.Content); i += 2 {
			lists = append(lists, sub.Content[i])
		}
	}
	for _, list := range lists {
		if list == nil {
			continue
		}
		for _, rule := range list.Content {
			tp, _, target, _ := RC.ParseRulePayload(rule.Value, true)
			if tp == "SUB-RULE" || target != old {
				continue
			}
			suffix := ""
			body := rule.Value
			if strings.HasSuffix(body, ",no-resolve") {
				suffix, body = ",no-resolve", strings.TrimSuffix(body, ",no-resolve")
			}
			i := strings.LastIndex(body, ",")
			if i < 0 || strings.TrimSpace(body[i+1:]) != old {
				return errors.New("rule target cannot be rewritten")
			}
			rule.Value = body[:i+1] + replacement + suffix
		}
	}
	return nil
}
