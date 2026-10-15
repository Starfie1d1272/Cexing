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
func prepareRegionResources(ctx context.Context, root *yaml.Node, r Request) (map[*yaml.Node]*yaml.Node, int, error) {
	active := r.Region != nil && !r.Region.Disabled
	if r.Intent != nil && !r.Intent.Disabled && r.Intent.Template != nil {
		active = r.Intent.Template.TemplateID == "region"
	}
	if !active || r.Intent == nil || r.Intent.Disabled || len(r.Intent.Operations) == 0 {
		return nil, 0, nil
	}
	base, err := snapshotEditBaselines(ctx, root)
	if err != nil {
		return nil, 0, err
	}
	if err := applyEditIntentPhase(ctx, root, r.Intent, nil, nil, base, 1); err != nil {
		return nil, 0, err
	}
	return base, 2, nil
}
