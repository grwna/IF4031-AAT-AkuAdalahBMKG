package config_test

import (
	"strings"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/config"
)

func setValidEnv(t *testing.T) {
	t.Setenv("JWT_PUBLIC_KEY", "dummy")
	t.Setenv("AGGREGATOR_URL", "http://aggregator:8083")
}

func TestLoad_Defaults(t *testing.T) {
	setValidEnv(t)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != "8080" {
		t.Errorf("expected port 8080, got %s", cfg.Port)
	}
	if cfg.Issuer != "bnpb-auth-service" || cfg.Audience != "bnpb-client-api" {
		t.Errorf("unexpected issuer/audience: %s / %s", cfg.Issuer, cfg.Audience)
	}
	if cfg.Leeway != 0 {
		t.Errorf("expected leeway 0, got %v", cfg.Leeway)
	}
	if cfg.AggregatorTimeout != 2*time.Second {
		t.Errorf("expected aggregator timeout 2s, got %v", cfg.AggregatorTimeout)
	}
	if cfg.MaxConcurrentRequests != 100 {
		t.Errorf("expected max concurrent requests 100, got %d", cfg.MaxConcurrentRequests)
	}
}

func TestLoad_TrimsTrailingSlash(t *testing.T) {
	setValidEnv(t)
	t.Setenv("AGGREGATOR_URL", "http://aggregator:8083/")

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.AggregatorURL != "http://aggregator:8083" {
		t.Errorf("expected trailing slash trimmed, got %s", cfg.AggregatorURL)
	}
}

func TestLoad_MissingRequired(t *testing.T) {
	t.Setenv("JWT_PUBLIC_KEY", "")
	t.Setenv("AGGREGATOR_URL", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error for missing env")
	}
	for _, key := range []string{"JWT_PUBLIC_KEY", "AGGREGATOR_URL"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error should mention %s, got: %v", key, err)
		}
	}
}

func TestLoad_InvalidValues(t *testing.T) {
	cases := map[string][2]string{
		"relative url":        {"AGGREGATOR_URL", "aggregator:8083"},
		"non-http scheme":     {"AGGREGATOR_URL", "ftp://aggregator:8083"},
		"negative leeway":     {"JWT_LEEWAY_SECONDS", "-1"},
		"zero timeout":        {"AGGREGATOR_TIMEOUT_MS", "0"},
		"zero max concurrent": {"MAX_CONCURRENT_REQUESTS", "0"},
	}
	for name, kv := range cases {
		t.Run(name, func(t *testing.T) {
			setValidEnv(t)
			t.Setenv(kv[0], kv[1])

			_, err := config.Load()
			if err == nil {
				t.Fatalf("expected error for %s=%s", kv[0], kv[1])
			}
			if !strings.Contains(err.Error(), kv[0]) {
				t.Errorf("error should mention %s, got: %v", kv[0], err)
			}
		})
	}
}
