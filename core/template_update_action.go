package main

import (
	"context"
	"encoding/json"
	"io"
	"strings"

	"core/profiletemplates"
)

// A bounded, pure worker operation. The owning version dispatcher routes only
// template-update-preview here; it never stages, saves or applies the result.
func coreTemplateUpdateAction(input string, homes ...string) string {
	fail := func(code string) string {
		value, _ := json.Marshal(map[string]string{"error": code})
		return string(value)
	}
	if len(input) > maxConfigBytes*3+2*1024*1024 {
		return fail("TEMPLATE_UPDATE_LIMIT")
	}
	var request struct {
		Op      string                          `json:"op"`
		Request *profiletemplates.UpdateRequest `json:"request,omitempty"`
		Source  *templateUpdateSourceInput      `json:"source,omitempty"`
	}
	decoder := json.NewDecoder(strings.NewReader(input))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF || request.Op != "template-update-preview" {
		return fail("TEMPLATE_UPDATE_INVALID")
	}
	if request.Source != nil {
		if request.Request != nil || len(homes) != 1 {
			return fail("TEMPLATE_UPDATE_CONTEXT")
		}
		result, err := templateUpdateSource(homes[0], *request.Source)
		if err != nil {
			return fail(err.Error())
		}
		data, err := json.Marshal(result)
		if err != nil {
			return fail("TEMPLATE_UPDATE_INVALID")
		}
		return string(data)
	}
	if request.Request == nil || len(input) > 4*1024*1024 {
		return fail("TEMPLATE_UPDATE_INVALID")
	}
	result, err := profiletemplates.PreviewUpdate(context.Background(), *request.Request)
	if err != nil {
		return fail(err.Error())
	} // service errors contain fixed categories only
	bytes, err := json.Marshal(result)
	if err != nil {
		return fail("TEMPLATE_UPDATE_INVALID")
	}
	return string(bytes)
}
