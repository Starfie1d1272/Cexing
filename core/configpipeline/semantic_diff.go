package configpipeline

import (
	"encoding/json"
	"reflect"
	"sort"

	RC "github.com/metacubex/mihomo/rules/common"
	"gopkg.in/yaml.v3"
)

// FieldChange exposes only allowlisted schema fields, never map keys supplied
// by a subscription (e.g. hosts or DNS policy domains), names, hashes or values.
type FieldChange struct {
	Field     string `json:"field"`
	Kind      string `json:"kind"`
	Before    int    `json:"before"`
	After     int    `json:"after"`
	Reordered bool   `json:"reordered,omitempty"`
}

var summarySections = []string{"proxies", "proxy-providers", "proxy-groups", "listeners", "rules", "rule-providers", "dns", "hosts", "tun", "mode", "external-controller", "external-ui", "allow-lan", "bind-address", "mixed-port", "port", "socks-port", "redir-port", "tproxy-port", "tunnels", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-doh-server", "external-ui-url", "external-ui-name", "external-controller-routing-mark", "external-controller-cors", "ss-config", "vmess-config", "tuic-server", "iptables", "ntp"}
var dnsSummaryFields = []string{"enable", "listen", "ipv6", "nameserver", "fallback", "default-nameserver", "proxy-server-nameserver", "direct-nameserver", "nameserver-policy", "proxy-server-nameserver-policy", "fallback-filter", "fake-ip-filter", "enhanced-mode", "fake-ip-range", "use-hosts", "use-system-hosts", "respect-rules", "prefer-h3"}

func decoded(n *yaml.Node) any {
	var v any
	if n != nil {
		_ = n.Decode(&v)
	}
	return v
}
func semanticEqual(a, b *yaml.Node) bool { return reflect.DeepEqual(decoded(a), decoded(b)) }
func mappingKeys(n *yaml.Node) []string {
	out := []string{}
	if n != nil && n.Kind == yaml.MappingNode {
		for i := 0; i < len(n.Content); i += 2 {
			out = append(out, n.Content[i].Value)
		}
	}
	return out
}
func sectionEqual(section string, a, b *yaml.Node) bool {
	if !semanticEqual(a, b) {
		return false
	}
	// Locked Mihomo consumes these maps in insertion order, unlike ordinary maps.
	if section == "dns" {
		for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
			if !reflect.DeepEqual(mappingKeys(field(a, key)), mappingKeys(field(b, key))) {
				return false
			}
		}
	}
	return true
}
func changeKind(a, b *yaml.Node) string {
	if a == nil {
		return "added"
	}
	if b == nil {
		return "removed"
	}
	if size(a) > 0 && size(b) == 0 {
		return "cleared"
	}
	return "modified"
}
func signatures(n *yaml.Node) []string {
	out := []string{}
	if n == nil || n.Kind != yaml.SequenceNode {
		return out
	}
	for _, entry := range n.Content {
		b, err := json.Marshal(decoded(entry))
		if err != nil {
			b, _ = yaml.Marshal(entry)
		}
		out = append(out, string(b))
	}
	return out
}
func commonOrderChanged(a, b []string) bool {
	ac, bc := map[string]int{}, map[string]int{}
	for _, v := range a {
		ac[v]++
	}
	for _, v := range b {
		bc[v]++
	}
	common := map[string]int{}
	for v, count := range ac {
		if bc[v] < count {
			count = bc[v]
		}
		common[v] = count
	}
	filtered := func(values []string) []string {
		out := []string{}
		seen := map[string]int{}
		for _, v := range values {
			seen[v]++
			if seen[v] <= common[v] {
				out = append(out, v)
			}
		}
		return out
	}
	return !reflect.DeepEqual(filtered(a), filtered(b))
}
func listDelta(a, b *yaml.Node) (added, removed, modified int, reordered bool) {
	as, bs := signatures(a), signatures(b)
	counts := map[string]int{}
	for _, v := range as {
		counts[v]++
	}
	for _, v := range bs {
		counts[v]--
	}
	for _, count := range counts {
		if count > 0 {
			removed += count
		} else {
			added -= count
		}
	}
	modified = added
	if removed < modified {
		modified = removed
	}
	added -= modified
	removed -= modified
	reordered = commonOrderChanged(as, bs)
	return
}
func namedEntries(section string, n *yaml.Node) map[string]*yaml.Node {
	out := map[string]*yaml.Node{}
	if n == nil {
		return out
	}
	if n.Kind == yaml.MappingNode {
		for i := 0; i < len(n.Content); i += 2 {
			out[n.Content[i].Value] = n.Content[i+1]
		}
	} else if n.Kind == yaml.SequenceNode {
		for _, entry := range n.Content {
			if name := field(entry, "name"); name != nil {
				out[name.Value] = entry
			}
		}
	}
	return out
}
func namedDelta(section string, a, b *yaml.Node, c *Change) {
	before, after := namedEntries(section, a), namedEntries(section, b)
	for name, old := range before {
		now, ok := after[name]
		if !ok {
			c.Removed++
			continue
		}
		if !semanticEqual(old, now) {
			c.Modified++
		}
		if !semanticEqual(field(old, "type"), field(now, "type")) {
			c.TypesChanged++
		}
		if section == "proxy-groups" {
			for _, key := range []string{"proxies", "use", "include-all", "include-all-proxies", "include-all-providers", "filter", "exclude-filter"} {
				if !semanticEqual(field(old, key), field(now, key)) {
					c.MembersChanged++
					break
				}
			}
		}
	}
	for name := range after {
		if _, ok := before[name]; !ok {
			c.Added++
		}
	}
	if a != nil && b != nil && a.Kind == yaml.SequenceNode && b.Kind == yaml.SequenceNode {
		names := func(n *yaml.Node) []string {
			out := []string{}
			for _, entry := range n.Content {
				if name := field(entry, "name"); name != nil {
					out = append(out, name.Value)
				}
			}
			return out
		}
		c.Reordered = commonOrderChanged(names(a), names(b))
	}
}
func ruleTypesChanged(a, b *yaml.Node) int {
	counts := map[string]int{}
	for index, n := range []*yaml.Node{a, b} {
		if n == nil || n.Kind != yaml.SequenceNode {
			continue
		}
		sign := 1
		if index == 1 {
			sign = -1
		}
		for _, rule := range n.Content {
			kind, _, _, _ := RC.ParseRulePayload(rule.Value, true)
			counts[kind] += sign
		}
	}
	positive, negative := 0, 0
	for _, n := range counts {
		if n > 0 {
			positive += n
		} else {
			negative -= n
		}
	}
	if positive < negative {
		return positive
	}
	return negative
}
func semanticChange(section string, a, b *yaml.Node) Change {
	c := Change{Section: section, Before: size(a), After: size(b), Kind: changeKind(a, b), ContentChanged: true}
	switch section {
	case "rules":
		c.Added, c.Removed, c.Modified, c.Reordered = listDelta(a, b)
		c.TypesChanged = ruleTypesChanged(a, b)
	case "proxies", "proxy-groups", "listeners", "proxy-providers", "rule-providers", "hosts":
		namedDelta(section, a, b, &c)
	case "dns":
		unknownBefore, unknownAfter := map[string]any{}, map[string]any{}
		known := map[string]bool{}
		for _, key := range dnsSummaryFields {
			known[key] = true
			old, now := field(a, key), field(b, key)
			ordered := key == "nameserver-policy" || key == "proxy-server-nameserver-policy"
			orderChanged := ordered && !reflect.DeepEqual(mappingKeys(old), mappingKeys(now)) && semanticEqual(old, now)
			if !semanticEqual(old, now) || orderChanged {
				c.Fields = append(c.Fields, FieldChange{Field: key, Kind: changeKind(old, now), Before: size(old), After: size(now), Reordered: orderChanged})
			}
		}
		for index, n := range []*yaml.Node{a, b} {
			if n != nil && n.Kind == yaml.MappingNode {
				target := unknownBefore
				if index == 1 {
					target = unknownAfter
				}
				for i := 0; i < len(n.Content); i += 2 {
					key := n.Content[i].Value
					if !known[key] {
						target[key] = decoded(n.Content[i+1])
					}
				}
			}
		}
		if !reflect.DeepEqual(unknownBefore, unknownAfter) {
			c.Fields = append(c.Fields, FieldChange{Field: "advanced", Kind: "modified", Before: len(unknownBefore), After: len(unknownAfter)})
		}
	default:
		c.Modified = 1
	}
	if c.Reordered && c.Added == 0 && c.Removed == 0 && c.Modified == 0 {
		c.Kind = "reordered"
	}
	return c
}
func summarizeChanges(before, after *yaml.Node) []Change {
	out := []Change{}
	known := map[string]bool{}
	for _, section := range summarySections {
		known[section] = true
		a, b := field(before, section), field(after, section)
		if !sectionEqual(section, a, b) {
			out = append(out, semanticChange(section, a, b))
		}
	}
	// Unrecognized top-level keys are grouped without exposing their names.
	collect := func(root *yaml.Node) *yaml.Node {
		n := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		if root != nil {
			for i := 0; i < len(root.Content); i += 2 {
				if !known[root.Content[i].Value] {
					n.Content = append(n.Content, root.Content[i], root.Content[i+1])
				}
			}
		}
		return n
	}
	a, b := collect(before), collect(after)
	if !semanticEqual(a, b) {
		out = append(out, semanticChange("advanced", a, b))
	}
	return out
}
func summarizePlatform(before, after *yaml.Node) []Change {
	out := []Change{}
	for _, c := range summarizeChanges(before, after) {
		// Adding host defaults is not an ignored user decision. Show only supplied
		// values changed by the actual projection; this service defines no policy.
		if c.Section == "advanced" {
			if c.Before == 0 {
				continue
			}
		} else if field(before, c.Section) == nil {
			continue
		}
		if c.Section == "dns" {
			fields := []FieldChange{}
			for _, f := range c.Fields {
				if field(field(before, "dns"), f.Field) != nil {
					fields = append(fields, f)
				}
			}
			c.Fields = fields
			if len(fields) == 0 {
				continue
			}
		}
		c.Kind = "protected"
		out = append(out, c)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Section < out[j].Section })
	return out
}
