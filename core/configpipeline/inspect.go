package configpipeline

import (
	"errors"
	"strings"
)

// InspectOffline performs deterministic YAML and reference checks without
// opening provider resources or contacting a network. The caller still needs
// the locked Mihomo parser before reporting a candidate as valid.
func InspectOffline(data []byte) (hasProviders bool, needsGeosite bool, err error) {
	root, err := parse(data)
	if err != nil {
		return false, false, errors.New("invalid YAML")
	}
	if err := rejectRuntimeCredential(root); err != nil {
		return false, false, errors.New("protected field")
	}
	if err := validateReferences(root); err != nil {
		return false, false, errors.New("invalid configuration references")
	}
	hasProviders = size(field(root, "proxy-providers")) > 0 || size(field(root, "rule-providers")) > 0
	// GEOSITE may appear in rules, DNS policies or nested logical rules. A
	// conservative text preflight prevents the upstream parser downloading a
	// missing geosite database during an offline check.
	needsGeosite = strings.Contains(strings.ToUpper(string(data)), "GEOSITE")
	return hasProviders, needsGeosite, nil
}
