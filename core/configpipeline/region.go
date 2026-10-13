package configpipeline

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"gopkg.in/yaml.v3"
)

// RegionPlan is stored per subscription. Assignments are explicit user
// corrections to name-based guesses; they never describe a node's true location.
type RegionPlan struct {
	Mode              string              `json:"mode"`
	Selector          string              `json:"selector"`
	Enable            bool                `json:"enable"`
	Disabled          bool                `json:"disabled,omitempty"`
	Assignments       map[string]string   `json:"assignments,omitempty"`
	ResolvedProviders map[string][]string `json:"-"`
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
	return PreviewRegionWithProviders(root, selector, assignments, nil)
}

func PreviewRegionWithProviders(root *yaml.Node, selector string, assignments map[string]string,
	resolved map[string][]string) (RegionPreview, error) {
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
	providerNames := []string{}
	if use := field(selected, "use"); use != nil {
		for _, ref := range use.Content {
			providerNames = append(providerNames, ref.Value)
		}
	}
	if all := field(selected, "include-all"); all != nil && all.Value == "true" {
		if providers := field(root, "proxy-providers"); providers != nil {
			for i := 0; i < len(providers.Content); i += 2 {
				providerNames = append(providerNames, providers.Content[i].Value)
			}
		}
	}
	sort.Strings(providerNames)
	providerNames = uniqueStrings(providerNames)
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
	if all := field(selected, "include-all"); all != nil && all.Value == "true" {
		for name := range proxyNames {
			if _, already := p.Nodes[name]; already {
				continue
			}
			region := guessRegion(name)
			if override, ok := assignments[name]; ok {
				if !validRegion(override) {
					return p, errors.New("invalid region assignment")
				}
				region = override
			}
			p.Nodes[name] = region
			p.Counts[region]++
			if region == "未知" {
				p.Unknown++
			}
		}
	}
	filters, err := compileProviderFilters(field(selected, "filter"))
	if err != nil {
		return p, err
	}
	excludes, err := compileProviderFilters(field(selected, "exclude-filter"))
	if err != nil {
		return p, err
	}
	for _, provider := range providerNames {
		names, ok := resolved[provider]
		if !ok {
			p.ProviderPending = true
			continue
		}
		for _, name := range names {
			if strings.Contains(name, "`") {
				return p, errors.New("provider node name cannot be filtered exactly")
			}
			include, err := matchesProviderFilters(filters, name)
			if err != nil {
				return p, err
			}
			exclude, err := matchesProviderFilters(excludes, name)
			if err != nil {
				return p, err
			}
			if (len(filters) > 0 && !include) || (len(excludes) > 0 && exclude) {
				continue
			}
			if _, exists := p.Nodes[name]; exists {
				return p, errors.New("duplicate explicit and provider node")
			}
			region := guessRegion(name)
			if override, ok := assignments[name]; ok {
				if !validRegion(override) {
					return p, errors.New("invalid region assignment")
				}
				region = override
			}
			p.Nodes[name] = region
			p.Counts[region]++
			if region == "未知" {
				p.Unknown++
			}
		}
	}
	p.Eligible = !p.ProviderPending && len(p.Nodes) > 0
	return p, nil
}

func compileProviderFilters(node *yaml.Node) ([]*regexp2.Regexp, error) {
	if node == nil || node.Value == "" {
		return nil, nil
	}
	filters := []*regexp2.Regexp{}
	for _, part := range strings.Split(node.Value, "`") {
		compiled, err := regexp2.Compile(part, regexp2.None)
		if err != nil {
			return nil, errors.New("invalid provider filter")
		}
		compiled.MatchTimeout = 100 * time.Millisecond
		filters = append(filters, compiled)
	}
	return filters, nil
}

func matchesProviderFilters(filters []*regexp2.Regexp, name string) (bool, error) {
	for _, filter := range filters {
		matched, err := filter.MatchString(name)
		if err != nil {
			return false, errors.New("provider filter timed out")
		}
		if matched {
			return true, nil
		}
	}
	return false, nil
}

func uniqueStrings(values []string) []string {
	out := values[:0]
	for _, value := range values {
		if len(out) == 0 || out[len(out)-1] != value {
			out = append(out, value)
		}
	}
	return out
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
	p, err := PreviewRegionWithProviders(root, plan.Selector, plan.Assignments, plan.ResolvedProviders)
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
	providerNode := map[string]bool{}
	for _, names := range plan.ResolvedProviders {
		for _, name := range names {
			providerNode[name] = true
		}
	}
	if plan.Mode == "all" {
		members := []string{}
		for node := range p.Nodes {
			if !providerNode[node] {
				members = append(members, node)
			}
		}
		sort.Strings(members)
		if len(p.Nodes) < 2 {
			return errors.New("at least two nodes required")
		}
		name := base + " 全部"
		if used[name] {
			return errors.New("generated group name collision")
		}
		newGroups = append(newGroups, smartGroup(name, members, providerGroups(root, plan, p.Nodes, "")))
		newNames = append(newNames, name)
	} else {
		for _, region := range []string{"香港", "台湾", "日本", "新加坡", "美国", "韩国", "英国", "德国", "未知"} {
			members := []string{}
			for node, code := range p.Nodes {
				if code == region && !providerNode[node] {
					members = append(members, node)
				}
			}
			sort.Strings(members)
			uses := providerGroups(root, plan, p.Nodes, region)
			if len(members) == 0 && len(uses) == 0 {
				continue
			}
			name := base + " " + region
			if used[name] {
				return errors.New("generated group name collision")
			}
			newGroups = append(newGroups, smartGroup(name, members, uses))
			newNames = append(newNames, name)
		}
	}
	// The new entry sits inside the original Selector. Existing rules and the
	// original ordered choices are untouched; the new group never points back.
	top := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	set(top, "name", scalar(base))
	set(top, "type", scalar("select"))
	set(top, "proxies", sequence(newNames...))
	groups.Content = append(groups.Content, newGroups...)
	groups.Content = append(groups.Content, top)
	for _, group := range groups.Content {
		if field(group, "name").Value != plan.Selector {
			continue
		}
		members := field(group, "proxies")
		if members == nil {
			members = sequence()
			set(group, "proxies", members)
		}
		if members.Kind != yaml.SequenceNode {
			return errors.New("invalid selector members")
		}
		members.Content = append(members.Content, scalar(base))
		return nil
	}
	return errors.New("original selector missing")
}

func smartGroup(name string, members []string, providers map[string][]string) *yaml.Node {
	g := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	set(g, "name", scalar(name))
	set(g, "type", scalar("smart"))
	set(g, "proxies", sequence(members...))
	if len(providers) > 0 {
		uses, names := []string{}, []string{}
		for provider, selected := range providers {
			uses = append(uses, provider)
			names = append(names, selected...)
		}
		sort.Strings(uses)
		sort.Strings(names)
		names = uniqueStrings(names)
		quoted := make([]string, 0, len(names))
		for _, n := range names {
			quoted = append(quoted, regexp.QuoteMeta(n))
		}
		set(g, "use", sequence(uses...))
		set(g, "filter", scalar("^(?:"+strings.Join(quoted, "|")+")$"))
	}
	set(g, "uselightgbm", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	set(g, "collectdata", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
	set(g, "empty-fallback", scalar("REJECT"))
	return g
}

func providerGroups(root *yaml.Node, plan RegionPlan, nodes map[string]string, region string) map[string][]string {
	result := map[string][]string{}
	selected := map[string]bool{}
	if groups := field(root, "proxy-groups"); groups != nil {
		for _, group := range groups.Content {
			if field(group, "name").Value != plan.Selector {
				continue
			}
			if use := field(group, "use"); use != nil {
				for _, name := range use.Content {
					selected[name.Value] = true
				}
			}
			if all := field(group, "include-all"); all != nil && all.Value == "true" {
				for name := range plan.ResolvedProviders {
					selected[name] = true
				}
			}
			break
		}
	}
	for provider, names := range plan.ResolvedProviders {
		if !selected[provider] {
			continue
		}
		for _, name := range names {
			if code, ok := nodes[name]; ok && (region == "" || code == region) {
				result[provider] = append(result[provider], name)
			}
		}
	}
	return result
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
