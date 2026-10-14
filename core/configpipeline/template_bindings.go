package configpipeline

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"

	"gopkg.in/yaml.v3"
)

// Private successful provenance. Snapshots contain authored template items only;
// they hold no version-store handles and must never enter diagnostic exports.
type TemplateEntity struct {
	ID      string          `json:"id"`
	Section string          `json:"section"`
	Value   json.RawMessage `json:"value"`
}
type TemplateSnapshot struct {
	TemplateID string           `json:"templateId"`
	Version    int              `json:"version"`
	Entries    []TemplateEntity `json:"entries"`
	Deleted    []string         `json:"deleted,omitempty"`
}

// TemplateSession lives only within one compiler/editor worker call. The
// template service owns generation/capture; the common editor owns bindings.
type TemplateSession struct {
	Baseline *TemplateSnapshot
	Targets  map[string]*yaml.Node
	Capture  func(context.Context, *yaml.Node, map[string]*yaml.Node) (*TemplateSnapshot, error)
}
type TemplatePrepare func(context.Context, *yaml.Node, TemplatePlan) (*TemplateSession, error)

func TemplateTarget(templateID, entityID string) string {
	sum := sha256.Sum256([]byte("cexing-template\x00" + templateID + "\x00" + entityID))
	return hex.EncodeToString(sum[:])
}

var templateEntityID = regexp.MustCompile(`^[a-z][a-z0-9_./-]{0,127}$`)

func validateTemplateSnapshot(s *TemplateSnapshot) error {
	fail := errors.New("TEMPLATE_BASELINE_INVALID")
	if s == nil || !templateEntityID.MatchString(s.TemplateID) || s.Version < 1 || s.Entries == nil || len(s.Entries) > 512 || len(s.Deleted) > 512 {
		return fail
	}
	seen := map[string]bool{}
	total := 0
	for _, e := range s.Entries {
		if !templateEntityID.MatchString(e.ID) || seen[e.ID] || !editSectionAllowed(e.Section) || len(e.Value) > 64*1024 {
			return fail
		}
		n, err := jsonNode(e.Value)
		if err != nil || rejectRuntimeCredential(n) != nil {
			return fail
		}
		switch e.Section {
		case "rules":
			if n.Tag != "!!str" {
				return fail
			}
		default:
			if n.Kind != yaml.MappingNode {
				return fail
			}
		}
		seen[e.ID] = true
		total += len(e.Value)
		if total > MaxIntentBytes {
			return fail
		}
	}
	for _, id := range s.Deleted {
		if !templateEntityID.MatchString(id) || seen[id] {
			return fail
		}
		seen[id] = true
	}
	return nil
}
func (p TemplatePlan) validateSnapshots() error {
	if (p.Baseline == nil) != (p.Mine == nil) {
		return errors.New("TEMPLATE_BASELINE_MISMATCH")
	}
	if p.Baseline == nil {
		return nil
	}
	for _, s := range []*TemplateSnapshot{p.Baseline, p.Mine} {
		if validateTemplateSnapshot(s) != nil || s.TemplateID != p.TemplateID || s.Version != p.Version {
			return errors.New("TEMPLATE_BASELINE_INVALID")
		}
	}
	if len(p.Baseline.Deleted) > 0 {
		return errors.New("TEMPLATE_BASELINE_INVALID")
	}
	return nil
}
func (c Compiler) prepareIntentTemplate(ctx context.Context, root *yaml.Node, intent *EditIntent) (*TemplateSession, error) {
	if err := CheckEditIntent(intent); err != nil {
		return nil, err
	}
	if intent == nil || intent.Disabled || intent.Template == nil || intent.Template.TemplateID == "original" {
		return nil, nil
	}
	if c.PrepareTemplate == nil {
		return nil, applyIntentTemplate(ctx, root, intent, c.Template)
	}
	session, err := c.PrepareTemplate(ctx, root, *intent.Template)
	if err != nil || session == nil || session.Capture == nil || validateTemplateSnapshot(session.Baseline) != nil {
		return nil, intentError("template_failed", -1)
	}
	if session.Baseline.TemplateID != intent.Template.TemplateID || session.Baseline.Version != intent.Template.Version || len(session.Baseline.Deleted) > 0 || len(session.Targets) != len(session.Baseline.Entries) {
		return nil, intentError("template_failed", -1)
	}
	seen := map[*yaml.Node]bool{}
	for _, e := range session.Baseline.Entries {
		n, ok := session.Targets[TemplateTarget(session.Baseline.TemplateID, e.ID)]
		if !ok || n == nil || seen[n] {
			return nil, intentError("template_failed", -1)
		}
		nodes, _, err := editNodes(root, e.Section)
		if err != nil {
			return nil, intentError("template_failed", -1)
		}
		found := false
		for _, node := range nodes {
			if n == node {
				found = true
			}
		}
		expected, err := jsonNode(e.Value)
		if !found || err != nil || fingerprint(n) != fingerprint(expected) {
			return nil, intentError("template_failed", -1)
		}
		seen[n] = true
	}
	return session, nil
}
func sessionTargets(s *TemplateSession) map[string]*yaml.Node {
	if s == nil {
		return nil
	}
	return s.Targets
}
func boundID(bindings map[string]*yaml.Node, node *yaml.Node, fallback string) string {
	for id, n := range bindings {
		if n != nil && n == node {
			return id
		}
	}
	return fallback
}
func rebind(bindings map[string]*yaml.Node, old, next *yaml.Node) {
	for id, n := range bindings {
		if n == old {
			bindings[id] = next
		}
	}
}
func aliasSnapshot(root *yaml.Node, out *EditableSnapshot, bindings map[string]*yaml.Node) {
	for si := range out.Sections {
		section := &out.Sections[si]
		nodes, _, err := editNodes(root, section.Section)
		if err != nil || len(nodes) != len(section.Items) {
			continue
		}
		for i, n := range nodes {
			section.Items[i].ID = boundID(bindings, n, section.Items[i].ID)
		}
	}
}
func boundEditAnchor(section string, nodes []*yaml.Node, names []string, before string, bindings map[string]*yaml.Node) (int, error) {
	if before == "" {
		return len(names), nil
	}
	for i, n := range nodes {
		if boundID(bindings, n, targetID(section, names[i])) == before {
			return i, nil
		}
	}
	return 0, intentError("missing_anchor", -1)
}

// Capture uses the template service's value encoder, then records actual editor
// order. A template service must not silently return stale bindings or values.
func captureBoundTemplate(ctx context.Context, root *yaml.Node, session *TemplateSession) (*TemplateSnapshot, error) {
	mine, err := session.Capture(ctx, root, session.Targets)
	if err != nil || validateTemplateSnapshot(mine) != nil || mine.TemplateID != session.Baseline.TemplateID || mine.Version != session.Baseline.Version {
		return nil, intentError("template_capture_failed", -1)
	}
	byID := map[string]TemplateEntity{}
	deleted := map[string]bool{}
	for _, e := range mine.Entries {
		byID[e.ID] = e
	}
	for _, id := range mine.Deleted {
		deleted[id] = true
	}
	if len(byID)+len(deleted) != len(session.Baseline.Entries) {
		return nil, intentError("template_capture_failed", -1)
	}
	for _, e := range session.Baseline.Entries {
		n := session.Targets[TemplateTarget(mine.TemplateID, e.ID)]
		if n == nil {
			if !deleted[e.ID] {
				return nil, intentError("template_capture_failed", -1)
			}
			continue
		}
		current, ok := byID[e.ID]
		if !ok || current.Section != e.Section {
			return nil, intentError("template_capture_failed", -1)
		}
		value, err := jsonNode(current.Value)
		if err != nil || fingerprint(value) != fingerprint(n) {
			return nil, intentError("template_capture_failed", -1)
		}
	}
	ordered := []TemplateEntity{}
	for _, section := range editableSections {
		nodes, _, err := editNodes(root, section)
		if err != nil {
			return nil, err
		}
		for _, node := range nodes {
			for id, e := range byID {
				if e.Section == section && session.Targets[TemplateTarget(mine.TemplateID, id)] == node {
					ordered = append(ordered, e)
					delete(byID, id)
					break
				}
			}
		}
	}
	if len(byID) != 0 {
		return nil, intentError("template_capture_failed", -1)
	}
	mine.Entries = ordered
	return mine, nil
}
