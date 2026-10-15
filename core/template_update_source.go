package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"strconv"

	"core/configpipeline"
	"core/profiletemplates"
)

// Private inputs use the same original/Merge/settings projection as the common
// editor. No URL/provider fetch, candidate file, stage or successful pointer.
type templateUpdateSourceInput struct {
	ResolvedDraft  bool                               `json:"resolvedDraft,omitempty"`
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
	for _, directory := range []string{store.Root, filepath.Join(store.Root, previous.ID)} {
		info, e := os.Lstat(directory)
		if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return templateUpdateSourceReply{}, fail
		}
	}
	read := func(name string, limit int) ([]byte, error) {
		f, e := os.Open(filepath.Join(store.Root, previous.ID, name))
		if e != nil {
			return nil, e
		}
		defer f.Close()
		info, e := f.Stat()
		if e != nil || !info.Mode().IsRegular() {
			return nil, fail
		}
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
		EditIntent  json.RawMessage
	}
	if json.Unmarshal(provenance, &source) != nil {
		return templateUpdateSourceReply{}, fail
	}
	successful, err := configpipeline.DecodeEditIntent(source.EditIntent)
	if err != nil || successful == nil || successful.Template == nil || successful.Template.TemplateID != intent.Template.TemplateID {
		return templateUpdateSourceReply{}, fail
	}
	if !safeTemplateJSON(source.EditIntent) || !safeTemplateJSON(input.Intent) {
		return templateUpdateSourceReply{}, errors.New("TEMPLATE_UPDATE_PRECISION")
	}
	base, mine := successful.Template.Baseline, successful.Template.Mine
	// Successful provenance is authoritative for unchanged personal operations.
	// Provider refresh cannot rewrite the historical side of the comparison.
	if input.ResolvedDraft {
		// A paired draft was already rebased onto input.Original. Reconstruct its
		// current authoring Base/Mine there; applying its new guards to the old
		// successful Original would make a valid closed review unreopenable.
		encoded, _ := json.Marshal(intent)
		enabled, e := configpipeline.DecodeEditIntent(encoded)
		if e != nil {
			return templateUpdateSourceReply{}, fail
		}
		enabled.Disabled = false
		compiled, _, e := compileLayeredMergeWithIntent(home, input.Original, input.GlobalMerge, input.Overlay, input.Overrides, false, nil, enabled)
		if e != nil || compiled.EditIntent == nil || compiled.EditIntent.Template == nil || compiled.EditIntent.Template.Baseline == nil || compiled.EditIntent.Template.Mine == nil {
			return templateUpdateSourceReply{}, fail
		}
		base, mine = compiled.EditIntent.Template.Baseline, compiled.EditIntent.Template.Mine
	} else if base == nil || mine == nil || !reflect.DeepEqual(intent.Operations, successful.Operations) {
		oldOriginal, e := read("original.yaml", maxConfigBytes)
		if e != nil {
			return templateUpdateSourceReply{}, fail
		}
		oldOverlay, e := read("overlay.yaml", maxConfigBytes)
		if os.IsNotExist(e) {
			oldOverlay = nil
		} else if e != nil {
			return templateUpdateSourceReply{}, fail
		}
		oldBytes, _ := json.Marshal(intent)
		old, e := configpipeline.DecodeEditIntent(oldBytes)
		if e != nil {
			return templateUpdateSourceReply{}, fail
		}
		// New draft edits use their old successful template/source guards.
		old.Template = successful.Template
		old.Disabled = false
		compiled, _, e := compileLayeredMergeWithIntent(home, string(oldOriginal), source.GlobalMerge, string(oldOverlay), input.Overrides, false, nil, old)
		if e != nil || compiled.EditIntent == nil || compiled.EditIntent.Template == nil || compiled.EditIntent.Template.Baseline == nil || compiled.EditIntent.Template.Mine == nil {
			return templateUpdateSourceReply{}, fail
		}
		if base == nil {
			base = compiled.EditIntent.Template.Baseline
		}
		mine = compiled.EditIntent.Template.Mine
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
	request := profiletemplates.UpdateRequest{Kind: kind, Base: *base, Mine: *mine, Next: *next.Baseline}
	token, _ := json.Marshal(struct {
		Input   templateUpdateSourceInput
		Request profiletemplates.UpdateRequest
	}{Input: templateUpdateSourceInput{ResolvedDraft: input.ResolvedDraft, ProfileID: input.ProfileID, ProfileVersion: input.ProfileVersion, Original: input.Original, GlobalMerge: input.GlobalMerge, Overlay: input.Overlay, Overrides: input.Overrides, Intent: input.Intent}, Request: request})
	encodedRequest, _ := json.Marshal(request)
	if !safeTemplateJSON(encodedRequest) {
		return templateUpdateSourceReply{}, errors.New("TEMPLATE_UPDATE_PRECISION")
	}
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
	return profiletemplates.EqualSnapshots(a, b)
}

// ArkTS currently transports structured intent through JSON number values.
// Refuse an inexact round trip before it can become a personal patch. Existing
// text/advanced editing remains available; never silently round unknown data.
func safeTemplateJSON(data []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return true
		}
		if err != nil {
			return false
		}
		number, ok := token.(json.Number)
		if !ok {
			continue
		}
		value, err := strconv.ParseFloat(number.String(), 64)
		if err != nil {
			return false
		}
		before, ok := new(big.Rat).SetString(number.String())
		if !ok {
			return false
		}
		after, ok := new(big.Rat).SetString(strconv.FormatFloat(value, 'g', -1, 64))
		if !ok || before.Cmp(after) != 0 {
			return false
		}
	}
}
