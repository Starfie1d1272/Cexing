package configpipeline

import (
	"encoding/json"
	"errors"
	"io"
	"strings"

	"gopkg.in/yaml.v3"
)

type TemplateSwitchResult struct {
	Intent         *EditIntent `json:"intent,omitempty"`
	DependentCount int         `json:"dependentCount"`
}

// SwitchTemplate changes only private intent. The caller still previews and
// publishes through the existing revision/digest transaction.
func SwitchTemplate(input *EditIntent, next TemplatePlan, pauseDependents bool) (TemplateSwitchResult, error) {
	if input == nil || CheckEditIntent(input) != nil || next.Validate() != nil {
		return TemplateSwitchResult{}, errors.New("TEMPLATE_SWITCH_INVALID")
	}
	raw, _ := json.Marshal(input)
	intent, err := DecodeEditIntent(raw)
	if err != nil {
		return TemplateSwitchResult{}, err
	}
	current := intent.Template
	if current != nil && current.TemplateID != "original" && current.TemplateID != next.TemplateID {
		owner := current.TemplateID
		owned, names := map[string]bool{}, map[string]bool{}
		for _, snapshot := range []*TemplateSnapshot{current.Baseline, current.Mine} {
			if snapshot == nil {
				continue
			}
			for _, entry := range snapshot.Entries {
				owned[TemplateTarget(owner, entry.ID)] = true
				if entry.Section == "proxy-groups" || entry.Section == "proxies" {
					node, e := jsonNode(entry.Value)
					if e != nil {
						return TemplateSwitchResult{}, e
					}
					if name := field(node, "name"); name != nil {
						names[name.Value] = true
					}
				}
			}
			for _, id := range snapshot.Deleted {
				owned[TemplateTarget(owner, id)] = true
			}
		}
		dependent := map[string]bool{}
		dependentTargets := map[string]bool{}
		// Follow both reference names and stable entity IDs. A dependent added
		// group may later be updated/renamed and referenced under its new name.
		for changed := true; changed; {
			changed = false
			for _, op := range intent.Operations {
				if op.TemplateID != "" && op.TemplateID != owner {
					continue
				}
				isOwned := owned[op.Target] || op.TemplateID == owner
				isDependent := dependent[op.ID] || dependentTargets[op.Target] ||
					owned[op.Before] || dependentTargets[op.Before] || operationReferencesTemplate(op, names)
				if !isOwned && !isDependent {
					continue
				}
				if !isOwned && !dependent[op.ID] {
					dependent[op.ID] = true
					changed = true
				}
				if op.Section != "proxy-groups" && op.Section != "proxies" {
					continue
				}
				// Only an added/owned entity disappears. A dependent field patch
				// on a source group must not suspend its unrelated personal edits.
				if op.Kind != "add" && !(op.Kind == "rename" && (isOwned || dependentTargets[op.Target])) {
					continue
				}
				name := op.Name
				if op.Kind == "add" {
					node, e := jsonNode(op.Value)
					if e == nil {
						if n := field(node, "name"); n != nil {
							name = n.Value
						}
					}
				}
				if name != "" {
					if !names[name] {
						names[name] = true
						changed = true
					}
					id := targetID(op.Section, name)
					if !owned[id] && !dependentTargets[id] {
						dependentTargets[id] = true
						changed = true
					}
				}
			}
		}
		if len(dependent) > 0 && !pauseDependents && !intent.Disabled {
			return TemplateSwitchResult{DependentCount: len(dependent)}, nil
		}
		for i := range intent.Operations {
			op := &intent.Operations[i]
			if owned[op.Target] || dependent[op.ID] {
				op.TemplateID = owner
			}
		}
		if intent.TemplateArchives == nil {
			intent.TemplateArchives = map[string]TemplatePlan{}
		}
		intent.TemplateArchives[owner] = *current
	}
	// Restore the same template's authoring baseline; validation of changed
	// source/fields is deliberately left to the common compiler, never guessed.
	archived, hasArchive := intent.TemplateArchives[next.TemplateID]
	if current != nil && current.TemplateID == next.TemplateID && current.Version == next.Version {
		archived = *current
		hasArchive = true
	}
	if hasArchive && archived.Version == next.Version {
		archived.TargetGroup = next.TargetGroup
		if (current == nil || current.TemplateID != next.TemplateID) && archived.Region != nil && next.Region != nil && archived.Region.Selector == next.Region.Selector {
			region := *next.Region
			region.Assignments = archived.Region.Assignments
			next.Region = &region
		}
		archived.Region = next.Region
		archived.ReplaceRules = next.ReplaceRules
		next = archived
		delete(intent.TemplateArchives, next.TemplateID)
	}
	intent.Template = &next
	if next.TemplateID != "original" {
		intent.Disabled = false
	}
	if err := CheckEditIntent(intent); err != nil {
		return TemplateSwitchResult{}, err
	}
	return TemplateSwitchResult{Intent: intent}, nil
}

func operationReferencesTemplate(op EditOperation, names map[string]bool) bool {
	for _, raw := range []json.RawMessage{op.Value, op.Patch} {
		if len(raw) == 0 {
			continue
		}
		value, err := jsonNode(raw)
		if err != nil {
			continue
		}
		// Reuse the compiler's reference-aware rewrite, including parsed rule
		// targets, instead of matching strings in domains, headers or credentials.
		root := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		if op.Section == "rules" || op.Section == "proxies" || op.Section == "proxy-groups" {
			set(root, op.Section, &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: []*yaml.Node{value}})
		} else {
			continue
		}
		before := fingerprint(root)
		marker := "cexing-paused-reference"
		for names[marker] {
			marker += "_"
		}
		for name := range names {
			renameReferences(root, "proxy-groups", name, marker)
		}
		if fingerprint(root) != before {
			return true
		}
	}
	return false
}

func activeTemplateOperation(intent *EditIntent, op EditOperation) bool {
	return op.TemplateID == "" || (intent.Template != nil && op.TemplateID == intent.Template.TemplateID)
}
func validTemplateOwner(id string) bool {
	return id == "region" || id == "ai" || id == "automatic"
}

// A bounded, credential-free error envelope for the shared worker dispatch.
func DecodeTemplateSwitch(input string) (TemplateSwitchResult, error) {
	if len(input) > MaxIntentBytes+64*1024 {
		return TemplateSwitchResult{}, errors.New("TEMPLATE_SWITCH_LIMIT")
	}
	var request struct {
		Op              string       `json:"op"`
		Intent          *EditIntent  `json:"intent"`
		Next            TemplatePlan `json:"next"`
		PauseDependents bool         `json:"pauseDependents"`
	}
	decoder := json.NewDecoder(strings.NewReader(input))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF || request.Op != "template-switch-plan" {
		return TemplateSwitchResult{}, errors.New("TEMPLATE_SWITCH_INVALID")
	}
	return SwitchTemplate(request.Intent, request.Next, request.PauseDependents)
}
