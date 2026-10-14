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
