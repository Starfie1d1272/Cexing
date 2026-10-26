package configpipeline

import (
	"context"
	"errors"
	"testing"
)

func TestCompilerPreservesOnlyClosedValidationFailure(t *testing.T) {
	for _, code := range []string{"RESOURCE_MISSING", "PROVIDER_UNRESOLVED", "CORE_VALIDATION_FAILED"} {
		c := compiler()
		c.Validate = func(context.Context, []byte) error { return NewValidationFailure(code) }
		_, err := c.Compile(context.Background(), Request{Original: []byte(original)})
		if err == nil || err.Error() != code {
			t.Fatalf("lost fixed category %s: %v", code, err)
		}
	}
	c := compiler()
	c.Validate = func(context.Context, []byte) error { return errors.New("private-provider.example/token=synthetic") }
	_, err := c.Compile(context.Background(), Request{Original: []byte(original)})
	if err == nil || err.Error() != "full configuration validation failed" {
		t.Fatalf("arbitrary validator error escaped: %v", err)
	}
	if NewValidationFailure("private_identifier").Error() != "CORE_VALIDATION_FAILED" {
		t.Fatal("unknown code escaped")
	}
}
