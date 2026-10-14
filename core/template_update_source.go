package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"

	"core/configpipeline"
	"core/profiletemplates"
)

// Private inputs use the same original/Merge/settings projection as the common
// editor. No URL/provider fetch, candidate file, stage or successful pointer.
type templateUpdateSourceInput struct {
	ProfileID      string                             `json:"profileId"`
	ProfileVersion string                             `json:"profileVersion"`
	Original       string                             `json:"original"`
	GlobalMerge    string                             `json:"globalMerge"`
	Overlay        string                             `json:"overlay"`
	Overrides      string                             `json:"overrides"`
	Intent         json.RawMessage                    `json:"intent"`
	Action         string                             `json:"action"`
	Stamp          string                             `json:"stamp,omitempty"`
	Candidate      *profiletemplates.TemplateSnapshot `json:"candidate,omitempty"`
}
type templateUpdateSourceReply struct {
	Request *profiletemplates.UpdateRequest `json:"request,omitempty"`
	Stamp   string                          `json:"stamp,omitempty"`
	Intent  *configpipeline.EditIntent      `json:"intent,omitempty"`
}

func templateUpdateSource(home string, input templateUpdateSourceInput) (templateUpdateSourceReply, error) {
	fail := errors.New("TEMPLATE_UPDATE_SOURCE_CHANGED")
	if !filepath.IsAbs(home) || !profileIDPattern.MatchString(input.ProfileID) || len(input.Original) > maxConfigBytes || len(input.GlobalMerge) > maxConfigBytes || len(input.Overlay) > maxConfigBytes || len(input.Overrides) > 1024*1024 {
		return templateUpdateSourceReply{}, fail
	}
	intent, err := configpipeline.DecodeEditIntent(input.Intent)
	if err != nil || intent == nil || intent.Template == nil || intent.Template.TemplateID == "original" {
		return templateUpdateSourceReply{}, fail
	}
	store := configpipeline.FileStore{Root: filepath.Join(home, "profile-versions")}
	state, err := store.Load(context.Background())
	if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	previous, ok := state.Profiles[input.ProfileID]
	if !ok || previous.ID != input.ProfileVersion {
		return templateUpdateSourceReply{}, fail
	}
	read := func(name string, limit int) ([]byte, error) {
		f, e := os.Open(filepath.Join(store.Root, previous.ID, name))
		if e != nil {
			return nil, e
		}
		defer f.Close()
		b, e := io.ReadAll(io.LimitReader(f, int64(limit)+1))
		if len(b) > limit {
			return nil, fail
		}
		return b, e
	}
	provenance, err := read("source.json", maxConfigBytes*6+2*1024*1024)
	if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	var source struct {
		GlobalMerge string
		EditIntent  *configpipeline.EditIntent
	}
	if json.Unmarshal(provenance, &source) != nil || source.EditIntent == nil || source.EditIntent.Template == nil || source.EditIntent.Template.TemplateID != intent.Template.TemplateID {
		return templateUpdateSourceReply{}, fail
	}
	oldOriginal, err := read("original.yaml", maxConfigBytes)
	if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	oldOverlay, err := read("overlay.yaml", maxConfigBytes)
	if os.IsNotExist(err) {
		oldOverlay = nil
	} else if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	oldBytes, _ := json.Marshal(intent)
	old, err := configpipeline.DecodeEditIntent(oldBytes)
	if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	// Read current personal edits against their successful old template and source.
	// A changed form target is Next, never a reason to apply old guards to Next.
	old.Template = source.EditIntent.Template
	old.Disabled = false
	compiled, _, err := compileLayeredMergeWithIntent(home, string(oldOriginal), source.GlobalMerge, string(oldOverlay), input.Overrides, false, nil, old)
	if err != nil || compiled.EditIntent == nil || compiled.EditIntent.Template == nil || compiled.EditIntent.Template.Baseline == nil || compiled.EditIntent.Template.Mine == nil {
		return templateUpdateSourceReply{}, fail
	}
	base := compiled.EditIntent.Template.Baseline
	if source.EditIntent.Template.Baseline != nil {
		base = source.EditIntent.Template.Baseline
	}
	root, err := configpipeline.LayeredMergeSource([]byte(input.Original), []byte(input.GlobalMerge), []byte(input.Overlay))
	if err != nil {
		return templateUpdateSourceReply{}, fail
	}
	next, err := editorTemplatePrepare(home)(context.Background(), root, *intent.Template)
	if err != nil || next == nil {
		return templateUpdateSourceReply{}, fail
	}
	kind := "subscription"
	if next.Baseline.Version > base.Version {
		kind = "template"
	}
	request := profiletemplates.UpdateRequest{Kind: kind, Base: *base, Mine: *compiled.EditIntent.Template.Mine, Next: *next.Baseline}
	token, _ := json.Marshal(struct {
		Input   templateUpdateSourceInput
		Request profiletemplates.UpdateRequest
	}{Input: templateUpdateSourceInput{ProfileID: input.ProfileID, ProfileVersion: input.ProfileVersion, Original: input.Original, GlobalMerge: input.GlobalMerge, Overlay: input.Overlay, Overrides: input.Overrides, Intent: input.Intent}, Request: request})
	digest := sha256.Sum256(token)
	stamp := hex.EncodeToString(digest[:])
	switch input.Action {
	case "read":
		if input.Candidate != nil || input.Stamp != "" {
			return templateUpdateSourceReply{}, fail
		}
		return templateUpdateSourceReply{Request: &request, Stamp: stamp}, nil
	case "encode":
		if input.Stamp != stamp || input.Candidate == nil {
			return templateUpdateSourceReply{}, fail
		}
		c := configpipeline.Compiler{PrepareTemplate: editorTemplatePrepare(home)}
		r := configpipeline.Request{Original: []byte(input.Original), Intent: intent}
		for _, layer := range []string{input.GlobalMerge, input.Overlay} {
			if layer != "" {
				r.Overlays = append(r.Overlays, []byte(layer))
			}
		}
		result, err := profiletemplates.EncodeDelta(context.Background(), c, r, request.Base, request.Next, *input.Candidate)
		if err != nil {
			return templateUpdateSourceReply{}, err
		}
		// Verify emitted operations reproduce the chosen semantic snapshot through
		// the real platform/full validator before offering the inert draft to save.
		enabledBytes, _ := json.Marshal(result)
		enabled, _ := configpipeline.DecodeEditIntent(enabledBytes)
		enabled.Disabled = false
		verified, _, err := compileLayeredMergeWithIntent(home, input.Original, input.GlobalMerge, input.Overlay, input.Overrides, false, nil, enabled)
		if err != nil || verified.EditIntent == nil || verified.EditIntent.Template == nil || !sameTemplateSnapshot(verified.EditIntent.Template.Mine, input.Candidate) {
			return templateUpdateSourceReply{}, errors.New("TEMPLATE_DELTA_VALIDATION")
		}
		return templateUpdateSourceReply{Intent: result}, nil
	default:
		return templateUpdateSourceReply{}, fail
	}
}
func sameTemplateSnapshot(a, b *configpipeline.TemplateSnapshot) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	clone := func(s *configpipeline.TemplateSnapshot) any {
		data, _ := json.Marshal(s)
		var out map[string]any
		_ = json.Unmarshal(data, &out)
		deleted := append([]string{}, s.Deleted...)
		sort.Strings(deleted)
		out["deleted"] = deleted
		return out
	}
	return reflect.DeepEqual(clone(a), clone(b))
}
