package configpipeline

import (
	"errors"
	"net/url"
	"strings"

	RC "github.com/metacubex/mihomo/rules/common"
	"gopkg.in/yaml.v3"
)

func validateReferences(root *yaml.Node) error {
	targets := map[string]bool{}
	for _, name := range []string{"DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL"} {
		targets[name] = true
	}
	groups := map[string]*yaml.Node{}
	for _, section := range []string{"proxies", "proxy-groups", "listeners"} {
		list := field(root, section)
		if list == nil {
			continue
		}
		if list.Kind != yaml.SequenceNode {
			return errors.New("invalid named array")
		}
		seen := map[string]bool{}
		for _, entry := range list.Content {
			name := field(entry, "name")
			if name == nil || name.Tag != "!!str" || name.Value == "" || seen[name.Value] {
				return errors.New("invalid or duplicate name")
			}
			seen[name.Value] = true
			if section != "listeners" {
				if targets[name.Value] && !(section == "proxy-groups" && name.Value == "GLOBAL") {
					return errors.New("duplicate target name")
				}
				targets[name.Value] = true
			}
			if section == "proxy-groups" {
				groups[name.Value] = entry
			}
		}
	}
	providers := field(root, "proxy-providers")
	ruleProviders := field(root, "rule-providers")
	for _, section := range []*yaml.Node{providers, ruleProviders} {
		if section == nil {
			continue
		}
		if section.Kind != yaml.MappingNode {
			return errors.New("invalid provider mapping")
		}
		for i := 1; i < len(section.Content); i += 2 {
			p := section.Content[i]
			kind := field(p, "type")
			if kind == nil || kind.Tag != "!!str" {
				return errors.New("provider type required")
			}
			switch kind.Value {
			case "http":
				address := field(p, "url")
				if address == nil || address.Tag != "!!str" {
					return errors.New("HTTP provider URL required")
				}
				u, err := url.Parse(address.Value)
				if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || (u.Hostname() == "example.com" || u.Hostname() == "example.net" || u.Hostname() == "example.org" || strings.HasSuffix(u.Hostname(), ".example")) || strings.HasSuffix(u.Hostname(), ".invalid") || strings.Contains(address.Value, "${") || strings.Contains(address.Value, "<") {
					return errors.New("invalid or placeholder provider URL")
				}
			case "file":
				path := field(p, "path")
				if path == nil || path.Tag != "!!str" || path.Value == "" {
					return errors.New("file provider path required")
				}
			case "inline":
				payload := field(p, "payload")
				if payload == nil || payload.Kind != yaml.SequenceNode || len(payload.Content) == 0 {
					return errors.New("inline provider payload required")
				}
			default:
				return errors.New("unsupported provider type")
			}
		}
	}
	if size(field(root, "proxies")) == 0 && size(providers) == 0 {
		return errors.New("proxies or proxy-providers required")
	}
	for _, group := range groups {
		for _, key := range []string{"proxies", "use"} {
			list := field(group, key)
			if list == nil {
				continue
			}
			if list.Kind != yaml.SequenceNode {
				return errors.New("invalid group reference list")
			}
			for _, ref := range list.Content {
				if ref.Tag != "!!str" {
					return errors.New("invalid group reference")
				}
				if (key == "proxies" && !targets[ref.Value]) || (key == "use" && field(providers, ref.Value) == nil) {
					return errors.New("missing group target or proxy provider")
				}
			}
		}
	}
	// Reject group dependency cycles before handing the candidate to the core.
	visiting, done := map[string]bool{}, map[string]bool{}
	var visit func(string) error
	visit = func(name string) error {
		if visiting[name] {
			return errors.New("cyclic group dependency")
		}
		if done[name] {
			return nil
		}
		visiting[name] = true
		if list := field(groups[name], "proxies"); list != nil {
			for _, ref := range list.Content {
				if groups[ref.Value] != nil {
					if err := visit(ref.Value); err != nil {
						return err
					}
				}
			}
		}
		delete(visiting, name)
		done[name] = true
		return nil
	}
	for name := range groups {
		if err := visit(name); err != nil {
			return err
		}
	}
	for _, section := range []string{"proxies", "proxy-groups"} {
		if list := field(root, section); list != nil {
			for _, entry := range list.Content {
				if ref := field(entry, "dialer-proxy"); ref != nil && (ref.Tag != "!!str" || !targets[ref.Value]) {
					return errors.New("missing dialer target")
				}
			}
		}
	}
	sub := field(root, "sub-rules")
	if sub != nil && sub.Kind != yaml.MappingNode {
		return errors.New("invalid sub-rules")
	}
	lists := []*yaml.Node{field(root, "rules")}
	if sub != nil {
		for i := 1; i < len(sub.Content); i += 2 {
			lists = append(lists, sub.Content[i])
		}
	}
	for _, list := range lists {
		if list == nil {
			continue
		}
		if list.Kind != yaml.SequenceNode {
			return errors.New("rules must be arrays")
		}
		for _, rule := range list.Content {
			if rule.Tag != "!!str" {
				return errors.New("invalid rule")
			}
			tp, payload, target, _ := RC.ParseRulePayload(rule.Value, true)
			if target == "" || (tp == "SUB-RULE" && field(sub, target) == nil) || (tp != "SUB-RULE" && !targets[target]) {
				return errors.New("missing rule target")
			}
			if tp == "RULE-SET" && field(ruleProviders, payload) == nil {
				return errors.New("missing rule provider")
			}
		}
	}
	return nil
}
