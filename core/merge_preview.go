package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sort"

	"core/configpipeline"
	"gopkg.in/yaml.v3"
)

type mergePreview struct {
	Digest  string                  `json:"digest"`
	Changes []configpipeline.Change `json:"changes"`
}

// corePreviewMerge follows the pinned Verge dialect through configpipeline.
// It returns only fixed section counts and a digest, never candidate YAML.
func corePreviewMerge(home, original, overlay, overrides string) (string, error) {
	project := func(_ context.Context, root *yaml.Node) error {
		var before, after map[string]any
		if err := root.Decode(&before); err != nil {
			return err
		}
		if err := root.Decode(&after); err != nil {
			return err
		}
		projectPlatformConfig(after)
		keys := make([]string, 0, len(after))
		for key := range after {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			value := after[key]
			if old, ok := before[key]; ok && reflect.DeepEqual(old, value) {
				continue
			}
			var encoded yaml.Node
			if err := encoded.Encode(value); err != nil {
				return err
			}
			setPreviewField(root, key, &encoded)
		}
		for key := range before {
			if _, ok := after[key]; !ok {
				removePreviewField(root, key)
			}
		}
		return nil
	}
	validator := func(_ context.Context, content []byte) error {
		return coreValidateOffline(home, string(content), overrides)
	}
	result, err := (configpipeline.Compiler{Platform: project, Validate: validator}).Compile(
		context.Background(), configpipeline.Request{Original: []byte(original), Overlays: [][]byte{[]byte(overlay)}, Previous: []byte(original)})
	if err != nil {
		return "", errors.New("MERGE_PREVIEW_FAILED")
	}
	data, err := json.Marshal(mergePreview{Digest: result.Digest, Changes: result.Changes})
	if err != nil {
		return "", errors.New("MERGE_PREVIEW_FAILED")
	}
	return string(data), nil
}

func setPreviewField(root *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value == key {
			root.Content[i+1] = value
			return
		}
	}
	root.Content = append(root.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, value)
}

func removePreviewField(root *yaml.Node, key string) {
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value == key {
			root.Content = append(root.Content[:i], root.Content[i+2:]...)
			return
		}
	}
}
