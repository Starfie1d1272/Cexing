package configpipeline

import (
	"context"
	"gopkg.in/yaml.v3"
)

// EditorResourceSource is private host input for resource identity checks. It
// reuses the same authoring projection and alias bindings as editor reads.
// Never expose this node through a public preview, diagnostic or support export.
func (c Compiler) EditorResourceSource(ctx context.Context, r Request) (*yaml.Node, error) {
	return c.editSource(ctx, r)
}

// ApplyProviderResourceEdits projects only local provider declarations for the
// host cache resolver. Generated-group and rule operations are deferred until
// those entities exist. The normal compiler applies each operation once.
func ApplyProviderResourceEdits(ctx context.Context, root *yaml.Node, intent *EditIntent) error {
	return applyEditIntentPhase(ctx, root, intent, nil, nil, nil, 1)
}
func prepareRegionResources(ctx context.Context, root *yaml.Node, r Request) (*editPhaseState, int, error) {
	active := r.Region != nil && !r.Region.Disabled
	if r.Intent != nil && !r.Intent.Disabled && r.Intent.Template != nil {
		active = r.Intent.Template.TemplateID == "region" || r.Intent.Template.TemplateID == "routing"
	}
	if !active || r.Intent == nil || r.Intent.Disabled || len(r.Intent.Operations) == 0 {
		return nil, 0, nil
	}
	base, err := snapshotEditBaselines(ctx, root)
	if err != nil {
		return nil, 0, err
	}
	state := &editPhaseState{baselines: base, aliases: map[string]*yaml.Node{}}
	for _, section := range editableSections {
		nodes, names, err := editNodes(root, section)
		if err != nil {
			return nil, 0, err
		}
		for i, node := range nodes {
			state.aliases[targetID(section, names[i])] = node
		}
	}
	if err := applyEditIntentPhase(ctx, root, r.Intent, nil, nil, state, 1); err != nil {
		return nil, 0, err
	}
	return state, 2, nil
}

type resourceRename struct {
	index              int
	section, old, next string
}
type editPhaseState struct {
	baselines map[*yaml.Node]*yaml.Node
	aliases   map[string]*yaml.Node
	renames   []resourceRename
}

// Only references introduced by this deferred write see later resource renames.
// Existing generated fields already use the final resource identity; rewriting
// the whole root again would violate the order of later personal writes.
func projectDeferredReferences(root *yaml.Node, op EditOperation, index int, before []*yaml.Node, touched *yaml.Node, state *editPhaseState) error {
	if len(state.renames) == 0 || (op.Section != "proxy-groups" && op.Section != "proxies" && op.Section != "rules") {
		return nil
	}
	nodes, names, err := editNodes(root, op.Section)
	if err != nil {
		return err
	}
	known := map[*yaml.Node]bool{}
	for _, n := range before {
		known[n] = true
	}
	for i, n := range nodes {
		if !known[n] {
			touched = n
			state.aliases[targetID(op.Section, names[i])] = n
			break
		}
	}
	if touched == nil {
		return nil
	}
	if state.baselines[touched] == nil {
		base, err := normalize(touched, map[*yaml.Node]bool{})
		if err != nil {
			return err
		}
		state.baselines[touched] = base
	}
	fragment := touched
	if op.Kind == "update" && touched.Kind == yaml.MappingNode {
		patch, err := jsonNode(op.Patch)
		if err != nil {
			return err
		}
		fragment = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		for i := 0; i < len(patch.Content); i += 2 {
			key := patch.Content[i].Value
			set(fragment, key, field(touched, key))
		}
	}
	isolated := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	set(isolated, op.Section, &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: []*yaml.Node{fragment}})
	for _, rename := range state.renames {
		if rename.index > index {
			renameReferences(isolated, rename.section, rename.old, rename.next)
		}
	}
	return nil
}
