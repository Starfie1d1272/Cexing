package profiletemplates

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"sort"
	"strings"

	"core/configpipeline"
)

const deltaPrefix = "template-update/"

// EncodeDelta replaces only template-targeted operations. It asks the common
// compiler for guards/anchors, retains all ordinary personal operations, and
// emits field patches, explicit deletes/renames and bounded relative moves.
// It never constructs a full-list Merge or publishes anything.
func EncodeDelta(ctx context.Context, compiler configpipeline.Compiler, request configpipeline.Request,
	base, next, candidate TemplateSnapshot) (*configpipeline.EditIntent, error) {
	fail := errors.New("TEMPLATE_DELTA_INVALID")
	if request.Intent == nil || request.Intent.Template == nil || candidate.TemplateID != next.TemplateID || candidate.Version != next.Version {
		return nil, fail
	}
	if _, err := snapshot(base); err != nil {
		return nil, fail
	}
	fresh, err := snapshot(next)
	if err != nil {
		return nil, fail
	}
	desired, err := snapshot(candidate)
	if err != nil {
		return nil, fail
	}
	encoded, err := json.Marshal(request.Intent)
	if err != nil {
		return nil, fail
	}
	intent, err := configpipeline.DecodeEditIntent(encoded)
	if err != nil {
		return nil, fail
	}
	if intent.Template.TemplateID != next.TemplateID || intent.Template.Version != next.Version {
		return nil, fail
	}
	owned := map[string]bool{}
	for _, list := range []TemplateSnapshot{base, next, candidate} {
		for _, e := range list.Entries {
			owned[TemplateTarget(list.TemplateID, e.ID)] = true
		}
		for _, id := range list.Deleted {
			owned[TemplateTarget(list.TemplateID, id)] = true
		}
	}
	kept := []configpipeline.EditOperation{}
	for _, op := range intent.Operations {
		if op.TemplateID != "" && op.TemplateID != intent.Template.TemplateID {
			kept = append(kept, op)
			continue
		}
		if !owned[op.Target] && !strings.HasPrefix(op.ID, deltaPrefix) {
			kept = append(kept, op)
		}
	}
	// Read raw fresh-template guards before personal reference rewrites. The
	// common compiler preserves precisely this initial baseline for the batch.
	clean := *intent
	clean.Disabled = false
	clean.Operations = []configpipeline.EditOperation{}
	clean.Template = &configpipeline.TemplatePlan{TemplateID: intent.Template.TemplateID, Version: intent.Template.Version, TargetGroup: intent.Template.TargetGroup, Region: intent.Template.Region, ReplaceRules: intent.Template.ReplaceRules, Routing: intent.Template.Routing}
	view := request
	view.Intent = &clean
	list, err := compiler.EditorList(ctx, view)
	if err != nil {
		return nil, fail
	}
	anchors := map[string]string{}
	for _, section := range list.Sections {
		for _, item := range section.Items {
			if !owned[item.ID] {
				anchors[section.Section] = item.ID
				break
			}
		}
	}
	opID := func(entity, kind string) string {
		sum := sha256.Sum256([]byte(candidate.TemplateID + "\x00" + entity + "\x00" + kind))
		return deltaPrefix + hex.EncodeToString(sum[:])
	}
	moves, edits, renames, additions := []configpipeline.EditOperation{}, []configpipeline.EditOperation{}, []configpipeline.EditOperation{}, []configpipeline.EditOperation{}
	for _, section := range templateSections {
		oldOrder, newOrder := []string{}, []string{}
		for _, e := range next.Entries {
			if e.Section == section {
				if _, ok := desired[e.ID]; ok {
					oldOrder = append(oldOrder, e.ID)
				}
			}
		}
		for _, e := range candidate.Entries {
			if e.Section == section {
				if _, ok := fresh[e.ID]; ok {
					newOrder = append(newOrder, e.ID)
				}
			}
		}
		if !reflect.DeepEqual(oldOrder, newOrder) {
			before := anchors[section]
			for i := len(newOrder) - 1; i >= 0; i-- {
				id := newOrder[i]
				target := TemplateTarget(candidate.TemplateID, id)
				moves = append(moves, configpipeline.EditOperation{ID: opID(id, "move"), Kind: "move", Section: section, Target: target, Before: before})
				before = target
			}
		}
	}
	for _, e := range next.Entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		target, err := compiler.EditTarget(ctx, view, e.Section, TemplateTarget(next.TemplateID, e.ID))
		if err != nil {
			return nil, fail
		}
		want, exists := desired[e.ID]
		if exists && want.section != e.Section {
			return nil, fail
		}
		op := configpipeline.EditOperation{ID: opID(e.ID, "edit"), Section: e.Section, Target: target.Item.ID}
		if !exists {
			op.Kind = "delete"
			op.Expected = target.Item.Revision
			edits = append(edits, op)
			continue
		}
		if reflect.DeepEqual(fresh[e.ID].value, want.value) {
			continue
		}
		if e.Section == "rules" {
			op.Kind = "update"
			op.Expected = target.Item.Revision
			op.Value, _ = json.Marshal(want.value)
			edits = append(edits, op)
			continue
		}
		before, ok := fresh[e.ID].value.(map[string]any)
		if !ok {
			return nil, fail
		}
		after, ok := want.value.(map[string]any)
		if !ok {
			return nil, fail
		}
		patch := map[string]any{}
		remove := []string{}
		guards := map[string]string{}
		keys := map[string]bool{}
		for k := range before {
			keys[k] = true
		}
		for k := range after {
			keys[k] = true
		}
		sorted := []string{}
		for k := range keys {
			sorted = append(sorted, k)
		}
		sort.Strings(sorted)
		for _, k := range sorted {
			old, oldOK := before[k]
			value, newOK := after[k]
			if oldOK == newOK && reflect.DeepEqual(old, value) {
				continue
			}
			if k == "name" {
				name, ok := value.(string)
				if !newOK || !ok || name == "" {
					return nil, fail
				}
				renames = append(renames, configpipeline.EditOperation{ID: opID(e.ID, "rename"), Kind: "rename", Section: e.Section, Target: target.Item.ID, Expected: target.Item.Revision, Name: name})
				continue
			}
			guard, ok := target.Item.Fields[k]
			if !ok {
				guard = target.MissingFieldRevision
			}
			guards[k] = guard
			if newOK {
				patch[k] = value
			} else {
				remove = append(remove, k)
			}
		}
		if len(guards) > 0 {
			op.Kind = "update"
			op.Patch, _ = json.Marshal(patch)
			op.Remove = remove
			op.Preconditions = guards
			edits = append(edits, op)
		}
	}
	for i, e := range candidate.Entries {
		if _, ok := fresh[e.ID]; ok {
			continue
		}
		before := anchors[e.Section]
		for _, following := range candidate.Entries[i+1:] {
			if following.Section == e.Section {
				if _, ok := fresh[following.ID]; ok {
					before = TemplateTarget(next.TemplateID, following.ID)
					break
				}
			}
		}
		op := configpipeline.EditOperation{ID: opID(e.ID, "add"), Kind: "add", Section: e.Section, Target: TemplateTarget(next.TemplateID, e.ID), Before: before, Value: append(json.RawMessage(nil), e.Value...)}
		if value, ok := desired[e.ID].value.(map[string]any); ok {
			op.Name, _ = value["name"].(string)
		}
		additions = append(additions, op)
	}
	intent.Operations = append(moves, kept...)
	intent.Operations = append(intent.Operations, edits...)
	intent.Operations = append(intent.Operations, renames...)
	intent.Operations = append(intent.Operations, additions...)
	intent.Template.Baseline = &next
	intent.Template.Mine = &candidate
	if configpipeline.CheckEditIntent(intent) != nil {
		return nil, fail
	}
	return intent, nil
}

// EqualSnapshots compares normalized semantic values without float64 coercion.
// Order is meaningful within a section; tombstone order is not meaningful.
func EqualSnapshots(a, b *TemplateSnapshot) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if a.TemplateID != b.TemplateID || a.Version != b.Version {
		return false
	}
	left, err := snapshot(*a)
	if err != nil {
		return false
	}
	right, err := snapshot(*b)
	if err != nil || len(left) != len(right) {
		return false
	}
	for id, value := range left {
		other, ok := right[id]
		if !ok || value.section != other.section {
			return false
		}
		x, e := json.Marshal(value.value)
		if e != nil {
			return false
		}
		y, e := json.Marshal(other.value)
		if e != nil || string(x) != string(y) {
			return false
		}
	}
	for _, section := range templateSections {
		x, y := []string{}, []string{}
		for _, entry := range a.Entries {
			if entry.Section == section {
				x = append(x, entry.ID)
			}
		}
		for _, entry := range b.Entries {
			if entry.Section == section {
				y = append(y, entry.ID)
			}
		}
		if !reflect.DeepEqual(x, y) {
			return false
		}
	}
	x, y := append([]string{}, a.Deleted...), append([]string{}, b.Deleted...)
	sort.Strings(x)
	sort.Strings(y)
	return reflect.DeepEqual(x, y)
}
