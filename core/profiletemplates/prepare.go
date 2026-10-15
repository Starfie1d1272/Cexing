package profiletemplates

import (
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/text/language"
	"golang.org/x/text/language/display"
	"strings"

	"core/configpipeline"
	"gopkg.in/yaml.v3"
)

// TemplateTarget is a stable, opaque editor alias, independent of rule text,
// display names or list positions. The common compiler owns applying edits to
// these node bindings and updating a binding when an operation replaces a node.
func TemplateTarget(templateID, entityID string) string {
	return configpipeline.TemplateTarget(templateID, entityID)
}

// Prepare applies the authored template to the compiler's private merged root
// and captures only its generated entities. No upstream section is frozen.
func Prepare(ctx context.Context, root *yaml.Node, p Plan) (TemplateSnapshot, map[string]*yaml.Node, error) {
	base := TemplateSnapshot{TemplateID: p.TemplateID, Version: p.Version, Entries: []Entity{}}
	targets := map[string]*yaml.Node{}
	var region configpipeline.RegionPreview
	if p.TemplateID == "region" {
		if err := p.Validate(); err != nil {
			return TemplateSnapshot{}, nil, err
		}
		var err error
		region, err = configpipeline.PreviewRegionWithProviders(root, p.Region.Selector, p.Region.Assignments, p.Region.ResolvedProviders)
		if err != nil {
			return TemplateSnapshot{}, nil, errors.New("TEMPLATE_REGION_UNAVAILABLE")
		}
	}
	if err := Apply(ctx, root, p); err != nil {
		return TemplateSnapshot{}, nil, err
	}
	add := func(id, section string, node *yaml.Node) error {
		var value any
		if node == nil || node.Decode(&value) != nil {
			return errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		base.Entries = append(base.Entries, Entity{id, section, encoded})
		targets[TemplateTarget(p.TemplateID, id)] = node
		return nil
	}
	if p.TemplateID == "ai" || p.TemplateID == "automatic" {
		rules, err := Rules(p)
		if err != nil {
			return TemplateSnapshot{}, nil, err
		}
		nodes := field(root, "rules")
		if nodes == nil || len(nodes.Content) < len(rules) {
			return TemplateSnapshot{}, nil, errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		for i, rule := range rules {
			if nodes.Content[i].Value != rule.Text {
				return TemplateSnapshot{}, nil, errors.New("TEMPLATE_CAPTURE_INVALID")
			}
			if err := add(rule.ID, "rules", nodes.Content[i]); err != nil {
				return TemplateSnapshot{}, nil, err
			}
		}
	}
	if p.TemplateID == "region" {
		groups := field(root, "proxy-groups")
		byName := map[string]*yaml.Node{}
		if groups != nil {
			for _, group := range groups.Content {
				if name := field(group, "name"); name != nil {
					byName[name.Value] = group
				}
			}
		}
		top := byName["Cexing Smart "+p.Region.Selector]
		members := field(top, "proxies")
		if members == nil {
			return TemplateSnapshot{}, nil, errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		codes := []string{}
		for _, code := range region.Regions {
			if region.Counts[code] > 0 {
				codes = append(codes, code)
			}
		}
		if p.Region.Mode == "all" {
			codes = []string{"all"}
		}
		if len(codes) != len(members.Content) {
			return TemplateSnapshot{}, nil, errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		for i, name := range members.Content {
			id, known := regionEntityIDs[codes[i]]
			if !known {
				return TemplateSnapshot{}, nil, errors.New("TEMPLATE_REGION_UNAVAILABLE")
			}
			if err := add(id, "proxy-groups", byName[name.Value]); err != nil {
				return TemplateSnapshot{}, nil, err
			}
		}
		if err := add("region/entry", "proxy-groups", top); err != nil {
			return TemplateSnapshot{}, nil, err
		}
	}
	if _, err := snapshot(base); err != nil {
		return TemplateSnapshot{}, nil, err
	}
	return base, targets, nil
}

// CaptureEdited reads the common compiler's updated bindings. A removed entry
// has an explicit nil binding; a stale/unreachable pointer is rejected rather
// than silently reverting the user's edit. Node bindings are never persisted.
func CaptureEdited(ctx context.Context, root *yaml.Node, base TemplateSnapshot, targets map[string]*yaml.Node) (TemplateSnapshot, error) {
	out := TemplateSnapshot{TemplateID: base.TemplateID, Version: base.Version, Entries: []Entity{}}
	reachable := map[*yaml.Node]bool{}
	var visit func(*yaml.Node)
	visit = func(n *yaml.Node) {
		if n == nil || reachable[n] {
			return
		}
		reachable[n] = true
		for _, child := range n.Content {
			visit(child)
		}
	}
	visit(root)
	for _, entity := range base.Entries {
		if err := ctx.Err(); err != nil {
			return TemplateSnapshot{}, err
		}
		target, known := targets[TemplateTarget(base.TemplateID, entity.ID)]
		if !known {
			return TemplateSnapshot{}, errors.New("TEMPLATE_BINDING_MISSING")
		}
		if target == nil {
			out.Deleted = append(out.Deleted, entity.ID)
			continue
		}
		if !reachable[target] {
			return TemplateSnapshot{}, errors.New("TEMPLATE_BINDING_STALE")
		}
		var value any
		if target.Decode(&value) != nil {
			return TemplateSnapshot{}, errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return TemplateSnapshot{}, errors.New("TEMPLATE_CAPTURE_INVALID")
		}
		out.Entries = append(out.Entries, Entity{entity.ID, entity.Section, encoded})
	}
	if _, err := snapshot(out); err != nil {
		return TemplateSnapshot{}, err
	}
	return out, nil
}

// Invert the already pinned CLDR display data to stable country IDs. This does
// not classify nodes or duplicate RegionPlan; the existing preview owns that.
var regionEntityIDs = func() map[string]string {
	out := map[string]string{"all": "region/all", "香港": "region/hk", "台湾": "region/tw", "未知": "region/other"}
	names := display.Regions(language.SimplifiedChinese)
	for a := 'A'; a <= 'Z'; a++ {
		for b := 'A'; b <= 'Z'; b++ {
			iso := string([]rune{a, b})
			region, err := language.ParseRegion(iso)
			if err == nil && region.IsCountry() && region.Canonicalize() == region {
				out[names.Name(region)] = "region/" + strings.ToLower(iso)
			}
		}
	}
	return out
}()
