package configpipeline

import "gopkg.in/yaml.v3"

// merge follows Clash Verge v2.5.8 use_merge (4337bd85758d54d7b9044b2da3c9ac1176eae1f3).
// Top-level overlay keys are ASCII-lowercased. Maps recurse, all other values
// replace (including arrays and null). DNS direct children and hosts replace.
// Name-based group updates belong to Strategy, never generic Merge.
func merge(dst, patch *yaml.Node) {
	normalized := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	for i := 0; i < len(patch.Content); i += 2 {
		set(normalized, asciiLower(patch.Content[i].Value), patch.Content[i+1])
	}
	for i := 0; i < len(normalized.Content); i += 2 {
		key, v := normalized.Content[i].Value, normalized.Content[i+1]
		old := field(dst, key)
		switch {
		case key == "dns" && old != nil && old.Kind == yaml.MappingNode && v.Kind == yaml.MappingNode:
			for j := 0; j < len(v.Content); j += 2 {
				set(old, v.Content[j].Value, v.Content[j+1])
			}
			set(dst, key, old)
		case key == "hosts":
			set(dst, key, v)
		default:
			set(dst, key, deepMerge(old, v))
		}
	}
}
func deepMerge(dst, patch *yaml.Node) *yaml.Node {
	if dst == nil || dst.Kind != yaml.MappingNode || patch.Kind != yaml.MappingNode {
		return patch
	}
	for i := 0; i < len(patch.Content); i += 2 {
		key := patch.Content[i].Value
		set(dst, key, deepMerge(field(dst, key), patch.Content[i+1]))
	}
	return dst
}
func asciiLower(key string) string {
	b := []byte(key)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}
