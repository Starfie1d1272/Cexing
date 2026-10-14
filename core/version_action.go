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
	EditSection     string                     `json:"editSection,omitempty"`
	EditTarget      string                     `json:"editTarget,omitempty"`
	EditIntent      *configpipeline.EditIntent `json:"editIntent,omitempty"`
	ProfileID       string                     `json:"profileId"`
	Original        string                     `json:"original"`
	GlobalMerge     *string                    `json:"globalMerge,omitempty"`
	UpdateGlobal    bool                       `json:"updateGlobal,omitempty"`
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
	Identity      string                             `json:"identity,omitempty"`
	Digest        string                             `json:"digest,omitempty"`
	SmartPreview  *[]configpipeline.SmartGroupChange `json:"smartPreview,omitempty"`
	EditError     *configpipeline.IntentError        `json:"editError,omitempty"`
	Editable      *configpipeline.EditableSnapshot   `json:"editable,omitempty"`
	EditTarget    *configpipeline.EditTarget         `json:"editTarget,omitempty"`
	Version       *configpipeline.Version            `json:"version,omitempty"`
	State         *configpipeline.Snapshot           `json:"state,omitempty"`
	Receipt       string                             `json:"receipt,omitempty"`
	Error         string                             `json:"error,omitempty"`
	MergePreview  *mergePreview                      `json:"mergePreview,omitempty"`
	RegionPreview *configpipeline.RegionPreview      `json:"regionPreview,omitempty"`
}

func coreVersionAction(home, input string) string {
	var diagnostic diagnosticAction
	if json.Unmarshal([]byte(input), &diagnostic) == nil && (diagnostic.Op == "diagnostics-record" || diagnostic.Op == "diagnostics-export") {
		return coreDiagnosticAction(home, input)
	}
	var action versionAction
	if len(input) > maxConfigBytes*6+2*1024*1024 || json.Unmarshal([]byte(input), &action) != nil ||
		home == "" || !filepath.IsAbs(home) {
		return `{"error":"VERSION_INVALID"}`
	}
	var envelope struct {
		EditIntent json.RawMessage `json:"editIntent"`
	}
	if json.Unmarshal([]byte(input), &envelope) != nil {
		return `{"error":"VERSION_INVALID"}`
	}
	if len(envelope.EditIntent) > 0 && string(envelope.EditIntent) != "null" {
		decoded, err := configpipeline.DecodeEditIntent(envelope.EditIntent)
		if err != nil {
			data, _ := json.Marshal(versionResponse{Error: "EDIT_INTENT_FAILED", EditError: err.(*configpipeline.IntentError)})
			return string(data)
		}
		action.EditIntent = decoded
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
	global := prior.GlobalMerge
	if action.UpdateGlobal {
		if action.GlobalMerge == nil || len(*action.GlobalMerge) > maxConfigBytes {
			return versionResponse{}, errors.New("GLOBAL_MERGE_INVALID")
		}
		global = *action.GlobalMerge
	}
	if err := configpipeline.CheckEditIntent(action.EditIntent); err != nil {
		return editFailure(err)
	}
	switch action.Op {
	case "editor-identity":
		identity, e := editorIdentity(home, action, global)
		if e != nil {
			return versionResponse{}, e
		}
		return versionResponse{Identity: identity}, nil
