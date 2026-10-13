package configpipeline

import "gopkg.in/yaml.v3"

// LayeredMergeSource uses the existing pinned Verge dialect for both layers.
// It also supplies exactly the same merged view to region/provider previews.
func LayeredMergeSource(original, global, local []byte) (*yaml.Node, error) {
	root, err := RegionMergedSource(original, global)
	if err != nil {
		return nil, err
	}
	if len(local) == 0 {
		return root, nil
	}
	patch, err := parse(local)
	if err != nil {
		return nil, err
	}
	if err := rejectRuntimeCredential(patch); err != nil {
		return nil, err
	}
	merge(root, patch)
	return root, nil
}
