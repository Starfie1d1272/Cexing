// Package profiletemplates contains Cexing-authored templates. It does not save
// files or publish versions: the host composes Apply into configpipeline.Strategy.
package profiletemplates

import (
	"context"
	"errors"
	"strings"

	"core/configpipeline"
	"gopkg.in/yaml.v3"
)

const Version = 1

// Plan belongs in the existing immutable version's structured intent. Recompile
// it against the latest original and Merge inputs, never against generated YAML.
// ResolvedProviders in Region is a transient, locally verified host snapshot.
type Plan struct {
	TemplateID   string                     `json:"templateId"`
	Version      int                        `json:"version"`
	TargetGroup  string                     `json:"targetGroup,omitempty"`
	Region       *configpipeline.RegionPlan `json:"region,omitempty"`
	ReplaceRules bool                       `json:"replaceRules,omitempty"`
}

type Rule struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// AI domains are an intentionally small, locally authored baseline, not an
// imported rule list or a promise of login/API/model availability. Stable IDs
// identify entries independently of their position for template updates.
var aiDomains = []struct{ id, domain string }{
	{"chatgpt", "chatgpt.com"}, {"openai", "openai.com"},
	{"openai-assets", "oaistatic.com"}, {"openai-content", "oaiusercontent.com"},
	{"claude", "claude.ai"}, {"anthropic", "anthropic.com"},
	{"gemini", "gemini.google.com"}, {"gemini-api", "generativelanguage.googleapis.com"},
}

func (p Plan) Validate() error {
	if p.Version != Version {
		return errors.New("TEMPLATE_VERSION_UNSUPPORTED")
	}
	switch p.TemplateID {
	case "original":
		if p.TargetGroup != "" || p.Region != nil || p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	case "region":
		if p.Region == nil || p.Region.Disabled || !p.Region.Enable || p.Region.Mode != "region" || p.TargetGroup != "" || p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	case "ai", "automatic":
		if p.Region != nil || p.TargetGroup == "" || len(p.TargetGroup) > 256 || strings.ContainsAny(p.TargetGroup, ",\r\n\x00") ||
			(p.TemplateID == "automatic") != p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	default:
		return errors.New("TEMPLATE_UNKNOWN")
	}
	return nil
}

// Rules exposes only template-owned entries. No user configuration, provider URL
// or node credential is copied into the catalogue or errors.
func Rules(p Plan) ([]Rule, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	var rules []Rule
	if p.TemplateID != "ai" && p.TemplateID != "automatic" {
		return rules, nil
	}
	if p.TemplateID == "automatic" {
		for _, r := range []struct{ id, text string }{
			{"loopback4", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"},
			{"private10", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"},
			{"private172", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"},
			{"private192", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"},
			{"loopback6", "IP-CIDR6,::1/128,DIRECT,no-resolve"},
			{"private6", "IP-CIDR6,fc00::/7,DIRECT,no-resolve"},
			{"linklocal6", "IP-CIDR6,fe80::/10,DIRECT,no-resolve"},
		} {
			rules = append(rules, Rule{"local/" + r.id, r.text})
		}
	}
	for _, domain := range aiDomains {
		rules = append(rules, Rule{"ai/" + domain.id, "DOMAIN-SUFFIX," + domain.domain + "," + p.TargetGroup})
	}
	if p.TemplateID == "automatic" {
		rules = append(rules, Rule{"default", "MATCH," + p.TargetGroup})
	}
	return rules, nil
}

// Apply receives a fresh, normalized private mapping from the existing compiler.
// Original leaves the merged input untouched. Disabling/switching templates is
// accomplished by recompiling the original with a different Plan, not by trying
// to reverse a generated YAML document. Full reference/resource validation and
// stage/verify/apply/commit remain mandatory after this transform.
func Apply(ctx context.Context, root *yaml.Node, p Plan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := p.Validate(); err != nil {
		return err
	}
	if root == nil || root.Kind != yaml.MappingNode {
		return errors.New("TEMPLATE_SOURCE_INVALID")
	}
	switch p.TemplateID {
	case "original":
		return nil
	case "region":
		return configpipeline.ApplyRegion(ctx, root, *p.Region)
	}
	// Only a real named strategy group is accepted, never a special builtin or
	// implicit GLOBAL fallback. The normal compiler validates its members/providers.
	groups := field(root, "proxy-groups")
	var selected *yaml.Node
	if groups != nil && groups.Kind == yaml.SequenceNode {
		for _, group := range groups.Content {
			name := field(group, "name")
			if name != nil && name.Kind == yaml.ScalarNode && name.Value == p.TargetGroup {
				selected = group
				break
			}
		}
	}
	if selected == nil {
		return errors.New("TEMPLATE_TARGET_MISSING")
	}
	if !potentialMembers(selected) {
		return errors.New("TEMPLATE_TARGET_EMPTY")
	}
	existing := field(root, "rules")
	if existing != nil && existing.Kind != yaml.SequenceNode {
		return errors.New("TEMPLATE_RULES_INVALID")
	}
	rules, err := Rules(p)
	if err != nil {
		return err
	}
	generated := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, rule := range rules {
		generated.Content = append(generated.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: rule.Text})
	}
	if p.TemplateID == "ai" && existing != nil {
		generated.Content = append(generated.Content, existing.Content...)
	}
	set(root, "rules", generated)
	return nil
}

func field(root *yaml.Node, key string) *yaml.Node {
	if root == nil || root.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value == key {
			return root.Content[i+1]
		}
	}
	return nil
}
func set(root *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value == key {
			root.Content[i+1] = value
			return
		}
	}
	root.Content = append(root.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, value)
}

// A provider-backed target is resolved and fully checked by the host validator;
// a statically empty selector must not inherit Mihomo's implicit DIRECT fallback.
func potentialMembers(group *yaml.Node) bool {
	for _, key := range []string{"proxies", "use"} {
		if n := field(group, key); n != nil && n.Kind == yaml.SequenceNode && len(n.Content) > 0 {
			return true
		}
	}
	for _, key := range []string{"include-all", "include-all-proxies", "include-all-providers"} {
		if n := field(group, key); n != nil && n.Tag == "!!bool" && n.Value == "true" {
			return true
		}
	}
	return false
}
