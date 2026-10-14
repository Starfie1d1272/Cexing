package configpipeline

import (
	"context"
	"errors"
	"strings"

	"gopkg.in/yaml.v3"
)

// TemplatePlan is the shared schema for #149. profiletemplates.Plan can remain
// source-compatible as a type alias to this type, avoiding an import cycle.
type TemplatePlan struct {
	TemplateID   string      `json:"templateId"`
	Version      int         `json:"version"`
	TargetGroup  string      `json:"targetGroup,omitempty"`
	Region       *RegionPlan `json:"region,omitempty"`
	ReplaceRules bool        `json:"replaceRules,omitempty"`
}

// TemplateTransform is supplied by the host using profiletemplates.Apply. It
// runs before personal edits; it never owns platform policy or publication.
type TemplateTransform func(context.Context, *yaml.Node, TemplatePlan) error

func (p TemplatePlan) Validate() error {
	if p.Version != 1 {
		return errors.New("TEMPLATE_VERSION_UNSUPPORTED")
	}
	switch p.TemplateID {
	case "original":
		if p.TargetGroup != "" || p.Region != nil || p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	case "region":
		if p.Region == nil || p.Region.Disabled || !p.Region.Enable || p.Region.Mode != "region" || p.TargetGroup != "" || p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	case "ai", "automatic":
		if p.Region != nil || p.TargetGroup == "" || len(p.TargetGroup) > 256 || strings.ContainsAny(p.TargetGroup, ",\r\n\x00") || (p.TemplateID == "automatic") != p.ReplaceRules {
			return errors.New("TEMPLATE_OPTIONS_INVALID")
		}
	default:
		return errors.New("TEMPLATE_UNKNOWN")
	}
	return nil
}
func applyIntentTemplate(ctx context.Context, root *yaml.Node, intent *EditIntent, transform TemplateTransform) error {
	if err := CheckEditIntent(intent); err != nil {
		return err
	}
	if intent == nil || intent.Disabled || intent.Template == nil {
		return nil
	}
	if intent.Template.TemplateID == "original" {
		return nil
	}
	if transform == nil {
		return intentError("template_unavailable", -1)
	}
	if err := transform(ctx, root, *intent.Template); err != nil {
		return intentError("template_failed", -1)
	}
	return nil
}
