package configpipeline

import (
	"context"
	"errors"

	"gopkg.in/yaml.v3"
)

// SmartAuto retains load-balance algorithms and manual selectors. Only url-test
// is converted by default; explicit per-group choices use ApplySmartPolicy.
func SmartAuto(ctx context.Context, root *yaml.Node) error {
	return ApplySmartPolicy(ctx, root, true, nil)
}

type SmartGroupChange struct {
	ID       string `json:"id"`
	Before   string `json:"before"`
	After    string `json:"after"`
	Override bool   `json:"override"`
}

// PreviewSmartPolicy is read-only. No eligible groups is a successful empty
// result. Deleted upstream groups leave dormant choices for possible reappearance.
func PreviewSmartPolicy(root *yaml.Node, defaultEnabled bool, intent *EditIntent) ([]SmartGroupChange, error) {
	if err := CheckEditIntent(intent); err != nil {
		return nil, err
	}
	out := []SmartGroupChange{}
	groups := field(root, "proxy-groups")
	if groups == nil {
		return out, nil
	}
	if groups.Kind != yaml.SequenceNode {
		return nil, errors.New("invalid proxy groups")
	}
	for _, group := range groups.Content {
		name, kind := field(group, "name"), field(group, "type")
		if name == nil || name.Tag != "!!str" || kind == nil || kind.Tag != "!!str" {
			return nil, errors.New("invalid proxy group")
		}
		if kind.Value != "url-test" && kind.Value != "load-balance" {
			continue
		}
		id := targetID("proxy-groups", name.Value)
		convert := defaultEnabled && kind.Value == "url-test"
		override := false
		if intent != nil && !intent.Disabled {
			if choice, ok := intent.SmartGroups[id]; ok {
				convert = choice
				override = true
			}
		}
		after := kind.Value
		if convert {
			after = "smart"
		}
		out = append(out, SmartGroupChange{ID: id, Before: kind.Value, After: after, Override: override})
	}
	return out, nil
}

// ApplySmartPolicy runs after template/edits on a fresh merged input. Explicit
// choices override the global default only for url-test/load-balance. Existing
// Smart parameters, selectors, member order and references remain unchanged.
func ApplySmartPolicy(ctx context.Context, root *yaml.Node, defaultEnabled bool, intent *EditIntent) error {
	preview, err := PreviewSmartPolicy(root, defaultEnabled, intent)
	if err != nil {
		return err
	}
	choices := map[string]bool{}
	for _, item := range preview {
		choices[item.ID] = item.After == "smart"
	}
	groups := field(root, "proxy-groups")
	if groups == nil {
		return nil
	}
	for _, group := range groups.Content {
		if err := ctx.Err(); err != nil {
			return err
		}
		name, kind := field(group, "name"), field(group, "type")
		if !choices[targetID("proxy-groups", name.Value)] {
			continue
		}
		kind.Value = "smart"
		set(group, "strategy", nil) // meaningful only after explicit load-balance opt-in
		set(group, "uselightgbm", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
		set(group, "collectdata", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
		set(group, "prefer-asn", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
	}
	return nil
}
