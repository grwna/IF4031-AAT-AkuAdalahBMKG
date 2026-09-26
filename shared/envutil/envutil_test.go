package envutil_test

import (
	"os"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"
)

func TestStr_ReturnsEnvWhenSet(t *testing.T) {
	os.Setenv("TEST_STR_KEY", "hello")
	defer os.Unsetenv("TEST_STR_KEY")
	if got := envutil.Str("TEST_STR_KEY", "default"); got != "hello" {
		t.Fatalf("expected hello, got %s", got)
	}
}

func TestStr_ReturnsFallbackWhenEmpty(t *testing.T) {
	os.Unsetenv("TEST_STR_MISSING")
	if got := envutil.Str("TEST_STR_MISSING", "fallback"); got != "fallback" {
		t.Fatalf("expected fallback, got %s", got)
	}
}

func TestInt_ReturnsEnvWhenSet(t *testing.T) {
	os.Setenv("TEST_INT_KEY", "42")
	defer os.Unsetenv("TEST_INT_KEY")
	if got := envutil.Int("TEST_INT_KEY", 0); got != 42 {
		t.Fatalf("expected 42, got %d", got)
	}
}

func TestInt_ReturnsFallbackOnInvalid(t *testing.T) {
	os.Setenv("TEST_INT_BAD", "notanumber")
	defer os.Unsetenv("TEST_INT_BAD")
	if got := envutil.Int("TEST_INT_BAD", 99); got != 99 {
		t.Fatalf("expected 99, got %d", got)
	}
}

func TestInt_ReturnsFallbackWhenEmpty(t *testing.T) {
	os.Unsetenv("TEST_INT_MISSING")
	if got := envutil.Int("TEST_INT_MISSING", 7); got != 7 {
		t.Fatalf("expected 7, got %d", got)
	}
}
