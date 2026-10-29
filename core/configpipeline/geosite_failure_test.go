package configpipeline

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestMissingGeoSiteCodePrivacyAndCompilerBoundary(t *testing.T) {
	cases := []struct{ input, want string }{
		{"DNS FallbackGeosite[0] format error: load GeoSite data error, failed to decode geodata file: geosite.dat, base error: list gfw not found in geosite.dat", "GEOSITE_MISSING:gfw"},
		{"list secret-token-123 not found in geosite.dat", "GEOSITE_MISSING"},
		{"list https://example.invalid/?token=secret not found in geosite.dat", ""},
		{"list gfw not found in geoip.dat", ""},
		{"list gfw not found in geosite.dat: token=secret", ""},
	}
	for _, tc := range cases {
		if got := MissingGeoSiteCode(errors.New(tc.input)); got != tc.want {
			t.Errorf("category mismatch: got %q want %q", got, tc.want)
		}
	}
	if got := NewValidationFailure("GEOSITE_MISSING:secret-token-123").Error(); got != "CORE_VALIDATION_FAILED" {
		t.Fatal("unapproved category escaped")
	}
	for _, code := range []string{"GEOSITE_MISSING:gfw", "GEOSITE_MISSING"} {
		c := compiler()
		c.Validate = func(context.Context, []byte) error { return NewValidationFailure(code) }
		_, err := c.Compile(context.Background(), Request{Original: []byte(original)})
		if err == nil || err.Error() != code || strings.Contains(err.Error(), "secret") {
			t.Fatalf("failure lost or leaked: %v", err)
		}
	}
}
