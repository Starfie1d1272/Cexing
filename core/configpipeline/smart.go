package configpipeline

import (
	"context"
	"errors"

	"gopkg.in/yaml.v3"
)

// SmartAuto converts only automatic selector groups in the private generated
// document. Names, ordered members, providers and rule references stay intact.
// The original subscription is held separately by the version store.
func SmartAuto(_ context.Context, root *yaml.Node) error {
	groups := field(root, "proxy-groups")
	if groups == nil {
		return nil
	}
	if groups.Kind != yaml.SequenceNode {
		return errors.New("invalid proxy groups")
	}
	for _, group := range groups.Content {
		if group.Kind != yaml.MappingNode {
			return errors.New("invalid proxy group")
		}
		kind := field(group, "type")
		if kind == nil || kind.Kind != yaml.ScalarNode || kind.Tag != "!!str" {
			return errors.New("invalid proxy group type")
		}
		if kind.Value != "url-test" && kind.Value != "load-balance" {
			continue
		}
		kind.Value = "smart"
		set(group, "strategy", nil) // load-balance algorithm has no Smart meaning.
		set(group, "uselightgbm", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
		set(group, "collectdata", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
		set(group, "prefer-asn", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"})
	}
	return nil
}
