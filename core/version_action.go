package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"

	"core/configpipeline"
)

var profileIDPattern = regexp.MustCompile(`(?i)^[^/\\\x00-\x1f]{1,128}\.ya?ml$`)

type versionAction struct {
	Op              string                     `json:"op"`
	ProfileID       string                     `json:"profileId"`
	Original        string                     `json:"original"`
	Overlay         string                     `json:"overlay"`
	Metadata        string                     `json:"metadata"`
	Overrides       string                     `json:"overrides"`
	Expected        string                     `json:"expected"`
	VersionID       string                     `json:"versionId"`
	Active          bool                       `json:"active"`
	NewProfileID    string                     `json:"newProfileId"`
	SmartConversion bool                       `json:"smartConversion"`
	RegionPlan      *configpipeline.RegionPlan `json:"regionPlan,omitempty"`
}

type versionResponse struct {
	Version       *configpipeline.Version       `json:"version,omitempty"`
	State         *configpipeline.Snapshot      `json:"state,omitempty"`
	Receipt       string                        `json:"receipt,omitempty"`
	Error         string                        `json:"error,omitempty"`
	RegionPreview *configpipeline.RegionPreview `json:"regionPreview,omitempty"`
}

func coreVersionAction(home, input string) string {
	var action versionAction
	if len(input) > maxConfigBytes*2 || json.Unmarshal([]byte(input), &action) != nil ||
		home == "" || !filepath.IsAbs(home) {
		return `{"error":"VERSION_INVALID"}`
	}
	response, err := executeVersionAction(home, action)
	if err != nil {
		response = versionResponse{Error: err.Error()}
	}
	data, marshalErr := json.Marshal(response)
	if marshalErr != nil {
		return `{"error":"VERSION_FAILED"}`
	}
	return string(data)
}

func executeVersionAction(home string, action versionAction) (versionResponse, error) {
	ctx := context.Background()
	store := configpipeline.FileStore{Root: filepath.Join(home, "profile-versions")}
	prior, err := store.Load(ctx)
	if err != nil {
		return versionResponse{}, errors.New("VERSION_STATE_INVALID")
	}
	currentID := ""
	if prior.Current != nil {
		currentID = prior.Current.ID
	}
	if action.Op == "read" {
		return versionResponse{State: &prior}, nil
	}
	if action.Expected != currentID {
		return versionResponse{}, errors.New("VERSION_STALE")
	}
	switch action.Op {
	case "region-preview":
		if action.RegionPlan == nil || len(action.Original) > maxConfigBytes || len(action.Overlay) > maxConfigBytes {
			return versionResponse{}, errors.New("REGION_INVALID")
		}
		preview, err := previewRegion(action.Original, action.Overlay, *action.RegionPlan)
		if err != nil {
			return versionResponse{}, errors.New("REGION_PREVIEW_FAILED")
		}
		return versionResponse{RegionPreview: &preview}, nil
	case "verify":
		if len(action.VersionID) < len("version-x") || filepath.Base(action.VersionID) != action.VersionID {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		content, err := os.ReadFile(filepath.Join(store.Root, action.VersionID, "config.yaml"))
		if err != nil || len(content) > maxConfigBytes {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		receipt, err := validateCandidateWithReceipt(home, string(content), action.Overrides)
		if err != nil {
			return versionResponse{}, errors.New("VERSION_VERIFY_FAILED")
		}
		return versionResponse{Receipt: receipt}, nil
	case "stage":
		if !profileIDPattern.MatchString(action.ProfileID) || len(action.Original) > maxConfigBytes ||
			len(action.Overlay) > maxConfigBytes || len(action.Metadata) > 64*1024 ||
			!json.Valid([]byte(action.Metadata)) {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		var metadata map[string]any
		if json.Unmarshal([]byte(action.Metadata), &metadata) != nil || metadata == nil {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		result, receipt, err := compilePinnedMergeWithStrategies(home, action.Original, action.Overlay,
			action.Overrides, action.SmartConversion, action.RegionPlan)
		if err != nil || len(result.YAML) > maxConfigBytes {
			return versionResponse{}, errors.New("VERSION_COMPILE_FAILED")
		}
		result.ProfileID = action.ProfileID
		result.Metadata = action.Metadata
		result.SmartConversion = action.SmartConversion
		result.RegionPlan = action.RegionPlan
		version, err := store.Stage(ctx, result)
		if err != nil {
			return versionResponse{}, errors.New("VERSION_STAGE_FAILED")
		}
		return versionResponse{Version: &version, Receipt: receipt}, nil
	case "remove", "rename":
		if !profileIDPattern.MatchString(action.ProfileID) {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		version, exists := prior.Profiles[action.ProfileID]
		if !exists && (prior.Current == nil || prior.Current.ProfileID != action.ProfileID) {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		if !exists {
			version = *prior.Current
		}
		if action.Op == "rename" {
			if prior.Profiles == nil {
				prior.Profiles = make(map[string]configpipeline.Version)
			}
			if !profileIDPattern.MatchString(action.NewProfileID) || prior.Profiles[action.NewProfileID].ID != "" {
				return versionResponse{}, errors.New("VERSION_INVALID")
			}
			version.ProfileID = action.NewProfileID
			prior.Profiles[action.NewProfileID] = version
		}
		delete(prior.Profiles, action.ProfileID)
		if prior.Current != nil && prior.Current.ProfileID == action.ProfileID {
			if action.Op == "remove" {
				prior.Current = nil
			} else {
				prior.Current.ProfileID = action.NewProfileID
			}
		}
		if err := store.Publish(ctx, prior); err != nil {
			return versionResponse{}, errors.New("VERSION_COMMIT_FAILED")
		}
		return versionResponse{State: &prior}, nil
	case "commit", "discard":
		if len(action.VersionID) < len("version-x") || filepath.Base(action.VersionID) != action.VersionID {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		candidate := configpipeline.Version{ID: action.VersionID,
			Path: filepath.Join(store.Root, action.VersionID, "config.yaml")}
		var source struct{ ProfileID string }
		data, err := os.ReadFile(filepath.Join(store.Root, action.VersionID, "source.json"))
		if err != nil || json.Unmarshal(data, &source) != nil || !profileIDPattern.MatchString(source.ProfileID) {
			return versionResponse{}, errors.New("VERSION_INVALID")
		}
		candidate.ProfileID = source.ProfileID
		if action.Op == "commit" && action.ProfileID != "" {
			if !profileIDPattern.MatchString(action.ProfileID) {
				return versionResponse{}, errors.New("VERSION_INVALID")
			}
			candidate.ProfileID = action.ProfileID
		}
		if action.Op == "discard" {
			if err := store.Discard(ctx, candidate); err != nil {
				return versionResponse{}, errors.New("VERSION_DISCARD_FAILED")
			}
			return versionResponse{}, nil
		}
		if prior.Profiles == nil {
			prior.Profiles = make(map[string]configpipeline.Version)
		}
		prior.Profiles[candidate.ProfileID] = candidate
		if action.Active {
			prior.Previous = prior.Current
			prior.Current = &candidate
		}
		if err := store.Publish(ctx, prior); err != nil {
			return versionResponse{}, errors.New("VERSION_COMMIT_FAILED")
		}
		return versionResponse{State: &prior}, nil
	default:
		return versionResponse{}, errors.New("VERSION_INVALID")
	}
}
