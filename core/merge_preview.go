package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
	result, _, err := compilePinnedMerge(home, original, overlay, overrides)
	if err != nil {
		return "", errors.New("MERGE_PREVIEW_FAILED")
	}
	data, err := json.Marshal(mergePreview{Digest: result.Digest, Changes: result.Changes})
	if err != nil {
		return "", errors.New("MERGE_PREVIEW_FAILED")
	}
	return string(data), nil
}

func compilePinnedMerge(home, original, overlay, overrides string) (configpipeline.Result, string, error) {
	return compilePinnedMergeWithSmart(home, original, overlay, overrides, false)
}

func compilePinnedMergeWithSmart(home, original, overlay, overrides string, smartConversion bool) (configpipeline.Result, string, error) {
	return compilePinnedMergeWithStrategies(home, original, overlay, overrides, smartConversion, nil)
}

func compilePinnedMergeWithStrategies(home, original, overlay, overrides string, smartConversion bool,
	region *configpipeline.RegionPlan) (configpipeline.Result, string, error) {
	return compileLayeredMerge(home, original, "", overlay, overrides, smartConversion, region)
}

func compileLayeredMerge(home, original, global, overlay, overrides string, smartConversion bool,
	region *configpipeline.RegionPlan) (configpipeline.Result, string, error) {
	var resolvedRegion *configpipeline.RegionPlan
	if region != nil && !region.Disabled {
		root, err := configpipeline.LayeredMergeSource([]byte(original), []byte(global), []byte(overlay))
		if err != nil {
			return configpipeline.Result{}, "", err
		}
		members, err := regionProviderNames(home, root)
		if err != nil {
			return configpipeline.Result{}, "", err
		}
		copy := *region
		copy.ResolvedProviders = members
		resolvedRegion = &copy
	}
	project := func(_ context.Context, root *yaml.Node) error {
		var before, after map[string]any
		if err := root.Decode(&before); err != nil {
			return err
		}
		if err := root.Decode(&after); err != nil {
			return err
		}
		// The persistent candidate must reflect the same host settings as runtime
		// validation, including LAN consent. Neither Merge layer can bypass them.
		applyOverrides(after, overrides)
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
	receipt := ""
	validator := func(_ context.Context, content []byte) error {
		var err error
		receipt, err = validateCandidateWithReceipt(home, string(content), overrides)
		return err
	}
	var overlays [][]byte
	for _, layer := range []string{global, overlay} {
		if layer != "" {
			overlays = append(overlays, []byte(layer))
		}
	}
	var strategy configpipeline.Transform
	strategy = func(ctx context.Context, root *yaml.Node) error {
		if smartConversion {
			if err := configpipeline.SmartAuto(ctx, root); err != nil {
				return err
			}
		}
		if resolvedRegion != nil {
			return configpipeline.ApplyRegion(ctx, root, *resolvedRegion)
		}
		return nil
	}
	result, err := (configpipeline.Compiler{Platform: project, Validate: validator}).Compile(
		context.Background(), configpipeline.Request{Original: []byte(original), Overlays: overlays,
			Strategy: strategy, Previous: []byte(original)})
	return result, receipt, err
}

func previewRegion(home, original, overlay string, plan configpipeline.RegionPlan) (configpipeline.RegionPreview, error) {
	return previewLayeredRegion(home, original, "", overlay, plan)
}

func previewLayeredRegion(home, original, global, overlay string, plan configpipeline.RegionPlan) (configpipeline.RegionPreview, error) {
	root, err := configpipeline.LayeredMergeSource([]byte(original), []byte(global), []byte(overlay))
	if err != nil {
		return configpipeline.RegionPreview{}, err
	}
	providers, err := regionProviderNames(home, root)
	if err != nil {
		return configpipeline.PreviewRegion(root, plan.Selector, plan.Assignments)
	}
	return configpipeline.PreviewRegionWithProviders(root, plan.Selector, plan.Assignments, providers)
}

// The running core parses the generated candidate in /configs before applying it.
// Its in-process offline parser cannot run concurrently with a live TUN, so the
// live preflight checks resources and cache identity without mutating core state.
func validateCandidateWithReceipt(home, text, overrides string) (string, error) {
	runLock.Lock()
	live := tunListener != nil
	runLock.Unlock()
	if !live {
		return coreValidateOfflineWithReceipt(home, text, overrides)
	}
	providers, needsGeosite, err := configpipeline.InspectOffline([]byte(text))
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(home, "geoip.metadb")); err != nil {
		return "", err
	}
	if needsGeosite {
		if _, err := os.Stat(filepath.Join(home, "geosite.dat")); err != nil {
			return "", err
		}
	}
	if !providers {
		return "", nil
	}
	return localProviderSnapshot(text)
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
