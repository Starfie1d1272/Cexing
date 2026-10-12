package configpipeline

import (
	"errors"
	"gopkg.in/yaml.v3"
)

// Maps merge recursively; null deletes. Ordinary arrays replace. Top-level
// proxies/groups/listeners merge by name, retaining positions and appending new
// names. {$delete: true, name: ...} deletes a named entry. Rules replace with
// exact duplicates removed, preserving first-match order (no sorting).
func merge(dst, patch *yaml.Node, path string) error {
	for i := 0; i < len(patch.Content); i += 2 {
		key, v := patch.Content[i].Value, patch.Content[i+1]
		old := field(dst, key)
		if v.Tag == "!!null" {
			set(dst, key, nil)
			continue
		}
		if path == "" && (key == "proxies" || key == "proxy-groups" || key == "listeners") {
			merged, err := mergeNamed(old, v)
			if err != nil {
				return err
			}
			set(dst, key, merged)
			continue
		}
		if v.Kind == yaml.MappingNode {
			if old == nil || old.Kind != yaml.MappingNode {
				old = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			}
			if err := merge(old, v, path+"/"+key); err != nil {
				return err
			}
			set(dst, key, old)
		} else {
			set(dst, key, v)
		}
	}
	return nil
}
func mergeNamed(dst, patch *yaml.Node) (*yaml.Node, error) {
	if patch.Kind != yaml.SequenceNode {
		return nil, errors.New("named sections must be arrays")
	}
	if dst == nil {
		dst = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	}
	if dst.Kind != yaml.SequenceNode {
		return nil, errors.New("named sections must be arrays")
	}
	for _, list := range []*yaml.Node{dst, patch} {
		seen := map[string]bool{}
		for _, entry := range list.Content {
			name := field(entry, "name")
			if name == nil || name.Tag != "!!str" || name.Value == "" || seen[name.Value] {
				return nil, errors.New("invalid or duplicate named entry")
			}
			seen[name.Value] = true
		}
	}
	for _, entry := range patch.Content {
		name := field(entry, "name").Value
		index := -1
		for i, old := range dst.Content {
			if field(old, "name").Value == name {
				index = i
				break
			}
		}
		deletion := field(entry, "$delete")
		if deletion != nil {
			if deletion.Tag != "!!bool" || deletion.Value != "true" || len(entry.Content) != 4 {
				return nil, errors.New("invalid named deletion")
			}
			if index >= 0 {
				dst.Content = append(dst.Content[:index], dst.Content[index+1:]...)
			}
			continue
		}
		if index < 0 {
			dst.Content = append(dst.Content, entry)
		} else if err := merge(dst.Content[index], entry, "/named"); err != nil {
			return nil, err
		}
	}
	return dst, nil
}
