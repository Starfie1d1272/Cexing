// Package configpipeline compiles subscriptions without changing the running core.
package configpipeline

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"reflect"

	"gopkg.in/yaml.v3"
)

// Transform mutates a private YAML mapping. Platform is required and runs last.
// Implementations must not log inputs; callback errors are deliberately redacted.
type Transform func(context.Context, *yaml.Node) error

// Validator must perform the host's full Mihomo validation, including resources.
// It must not activate listeners. The host owns serialization and cleanup of any
// upstream parser side effects; there is no permissive default validator.
type Validator func(context.Context, []byte) error

type Compiler struct {
	Platform Transform
	Validate Validator
}
type Request struct {
	// Empty means no successful active version; otherwise use Snapshot.Current.ID.
	ExpectedActiveRevision string
	Original               []byte
	Overlays               [][]byte
	Strategy               Transform
	Previous               []byte
}

// Summary contains only fixed section names, never names, URLs or values.
type Change struct {
	Section       string
	Before, After int
}
type Result struct {
	Original []byte
	Overlays [][]byte
	YAML     []byte
	Digest   string
	Changes  []Change
}

func (c Compiler) Compile(ctx context.Context, r Request) (Result, error) {
	if c.Platform == nil || c.Validate == nil {
		return Result{}, errors.New("platform constraints and full validator are required")
	}
	root, err := parse(r.Original)
	if err != nil {
		return Result{}, errors.New("invalid original YAML")
	}
	for _, overlay := range r.Overlays {
		patch, err := parse(overlay)
		if err != nil {
			return Result{}, errors.New("invalid overlay YAML")
		}
		if err := merge(root, patch, ""); err != nil {
			return Result{}, err
		}
	}
	for _, step := range []struct {
		name string
		fn   Transform
	}{{"strategy", r.Strategy}, {"platform", c.Platform}} {
		if err := ctx.Err(); err != nil {
			return Result{}, err
		}
		if step.fn != nil {
			if err := step.fn(ctx, root); err != nil {
				return Result{}, errors.New(step.name + " transformation failed")
			}
		}
	}
	output, err := yaml.Marshal(root)
	if err != nil {
		return Result{}, errors.New("YAML generation failed")
	}
	// Reparse callback output: rejects duplicate/non-string keys and malformed nodes.
	checked, err := parse(output)
	if err != nil {
		return Result{}, errors.New("invalid transformed YAML")
	}
	if err := validateReferences(checked); err != nil {
		return Result{}, err
	}
	output, err = yaml.Marshal(checked)
	if err != nil {
		return Result{}, errors.New("YAML generation failed")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if err := c.Validate(ctx, append([]byte(nil), output...)); err != nil {
		return Result{}, errors.New("full configuration validation failed")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	sum := sha256.Sum256(output)
	result := Result{Original: append([]byte(nil), r.Original...), YAML: output, Digest: hex.EncodeToString(sum[:])}
	for _, b := range r.Overlays {
		result.Overlays = append(result.Overlays, append([]byte(nil), b...))
	}
	prior, _ := parse(r.Previous)
	for _, key := range []string{"proxies", "proxy-providers", "proxy-groups", "rules", "rule-providers", "dns", "tun", "external-controller", "secret", "external-ui"} {
		a, b := field(prior, key), field(checked, key)
		var av, bv any
		if a != nil {
			_ = a.Decode(&av)
		}
		if b != nil {
			_ = b.Decode(&bv)
		}
		if !reflect.DeepEqual(av, bv) {
			result.Changes = append(result.Changes, Change{key, size(a), size(b)})
		}
	}
	return result, nil
}

func parse(data []byte) (*yaml.Node, error) {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, errors.New("one document required")
	}
	if len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("mapping required")
	}
	// Decode detects duplicate keys (including nested maps) and invalid aliases.
	var value map[string]any
	if err := doc.Content[0].Decode(&value); err != nil {
		return nil, err
	}
	return normalize(doc.Content[0], map[*yaml.Node]bool{})
}

func normalize(n *yaml.Node, visiting map[*yaml.Node]bool) (*yaml.Node, error) {
	if n == nil || visiting[n] {
		return nil, errors.New("cyclic alias")
	}
	visiting[n] = true
	defer delete(visiting, n)
	if n.Kind == yaml.AliasNode {
		return normalize(n.Alias, visiting)
	}
	out := *n
	out.Anchor = ""
	out.Alias = nil
	out.Content = nil
	if n.Kind == yaml.MappingNode {
		// YAML merge defaults precede explicit keys. Earlier merge-sequence maps win.
		for i := 0; i < len(n.Content); i += 2 {
			k, v := n.Content[i], n.Content[i+1]
			if k.Tag != "!!merge" {
				continue
			}
			base, err := normalize(v, visiting)
			if err != nil {
				return nil, err
			}
			maps := []*yaml.Node{base}
			if base.Kind == yaml.SequenceNode {
				maps = base.Content
			}
			for _, m := range maps {
				if m.Kind != yaml.MappingNode {
					return nil, errors.New("invalid YAML merge")
				}
				for j := 0; j < len(m.Content); j += 2 {
					if field(&out, m.Content[j].Value) == nil {
						out.Content = append(out.Content, m.Content[j], m.Content[j+1])
					}
				}
			}
		}
		for i := 0; i < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Tag == "!!merge" {
				continue
			}
			if k.Kind != yaml.ScalarNode || k.Tag != "!!str" {
				return nil, errors.New("string keys required")
			}
			v, err := normalize(n.Content[i+1], visiting)
			if err != nil {
				return nil, err
			}
			set(&out, k.Value, v)
		}
	} else {
		for _, child := range n.Content {
			v, err := normalize(child, visiting)
			if err != nil {
				return nil, err
			}
			out.Content = append(out.Content, v)
		}
	}
	return &out, nil
}
func field(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}
func set(n *yaml.Node, key string, v *yaml.Node) {
	for i := 0; i < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			if v == nil {
				n.Content = append(n.Content[:i], n.Content[i+2:]...)
			} else {
				n.Content[i+1] = v
			}
			return
		}
	}
	if v != nil {
		n.Content = append(n.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, v)
	}
}
func size(n *yaml.Node) int {
	if n == nil {
		return 0
	}
	if n.Kind == yaml.MappingNode {
		return len(n.Content) / 2
	}
	if n.Kind == yaml.SequenceNode {
		return len(n.Content)
	}
	return 1
}
