package configpipeline

// ValidationFailure preserves a closed host diagnostic category across the
// compiler's privacy boundary. Arbitrary validator text must stay redacted.
type ValidationFailure struct{ code string }

func NewValidationFailure(code string) *ValidationFailure {
	if safeGeoSiteCode(code) {
		return &ValidationFailure{code: code}
	}
	switch code {
	case "GEOSITE_MISSING", "RESOURCE_MISSING", "PROVIDER_UNRESOLVED", "VALIDATOR_BUSY", "VALIDATOR_HOME", "CONFIG_INVALID", "CORE_VALIDATION_FAILED":
		return &ValidationFailure{code: code}
	default:
		return &ValidationFailure{code: "CORE_VALIDATION_FAILED"}
	}
}
func (e *ValidationFailure) Error() string { return e.code }
