package main

import (
	"context"

	"core/configpipeline"
	"core/profiletemplates"
	"gopkg.in/yaml.v3"
)

// The application composes its existing template service into every editor and
// compiler view. Conversion enforces the shared schema shape at compile time;
// profiletemplates remains unchanged and does not import the host.
func editorTemplate(home string) configpipeline.TemplateTransform {
	return func(ctx context.Context, root *yaml.Node, plan configpipeline.TemplatePlan) error {
		if plan.Region != nil {
			resolved, err := regionProviderNames(home, root)
			if err != nil {
				return err
			}
			region := *plan.Region
			region.ResolvedProviders = resolved
			plan.Region = &region
		}
		return profiletemplates.Apply(ctx, root, templateServicePlan(plan))
	}
}
func editorReadRequest(home string, action versionAction, global string) (configpipeline.Request, error) {
	request := configpipeline.Request{Original: []byte(action.Original), Intent: action.EditIntent}
	for _, layer := range []string{global, action.Overlay} {
		if layer != "" {
			request.Overlays = append(request.Overlays, []byte(layer))
		}
	}
	if action.RegionPlan != nil && !action.RegionPlan.Disabled && (action.EditIntent == nil || action.EditIntent.Disabled || action.EditIntent.Template == nil) {
		root, err := configpipeline.LayeredMergeSource([]byte(action.Original), []byte(global), []byte(action.Overlay))
		if err != nil {
			return configpipeline.Request{}, err
		}
		if err := configpipeline.ApplyProviderResourceEdits(context.Background(), root, action.EditIntent); err != nil {
			return configpipeline.Request{}, err
		}
		resolved, err := regionProviderNames(home, root)
		if err != nil {
			return configpipeline.Request{}, err
		}
		region := *action.RegionPlan
		region.ResolvedProviders = resolved
		request.Region = &region
	}
	return request, nil
}

func templateServicePlan(p configpipeline.TemplatePlan) profiletemplates.Plan {
	return profiletemplates.Plan{TemplateID: p.TemplateID, Version: p.Version, TargetGroup: p.TargetGroup, Region: p.Region, ReplaceRules: p.ReplaceRules}
}
func editorTemplatePrepare(home string) configpipeline.TemplatePrepare {
	return func(ctx context.Context, root *yaml.Node, plan configpipeline.TemplatePlan) (*configpipeline.TemplateSession, error) {
		if plan.Region != nil {
			resolved, err := regionProviderNames(home, root)
			if err != nil {
				return nil, err
			}
			region := *plan.Region
			region.ResolvedProviders = resolved
			plan.Region = &region
		}
		base, targets, err := profiletemplates.Prepare(ctx, root, templateServicePlan(plan))
		if err != nil {
			return nil, err
		}
		return &configpipeline.TemplateSession{Baseline: &base, Targets: targets, Capture: func(ctx context.Context, root *yaml.Node, targets map[string]*yaml.Node) (*configpipeline.TemplateSnapshot, error) {
			mine, err := profiletemplates.CaptureEdited(ctx, root, base, targets)
			return &mine, err
		}}, nil
	}
}
