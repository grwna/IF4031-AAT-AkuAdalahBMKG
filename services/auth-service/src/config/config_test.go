package config_test

import (
	"strings"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
)

func setValidEnv(t *testing.T) {
	t.Setenv("JWT_PRIVATE_KEY", "dummy")
	t.Setenv("REDIS_ADDR", "localhost:6379")
	for _, p := range []string{"CLIENT_MEDIA", "CLIENT_FIELD", "CLIENT_OPS"} {
		t.Setenv(p+"_ID", strings.ToLower(p))
		t.Setenv(p+"_SECRET", "secret")
		t.Setenv(p+"_SCOPE", "hazards:read:summary")
	}
}

func TestLoad_Defaults(t *testing.T) {
	setValidEnv(t)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != "8084" {
		t.Errorf("expected port 8084, got %s", cfg.Port)
	}
	if cfg.AccessTokenTTL != 60*time.Second {
		t.Errorf("expected access TTL 60s, got %v", cfg.AccessTokenTTL)
	}
	if cfg.RefreshTokenTTL != time.Hour {
		t.Errorf("expected refresh TTL 1h, got %v", cfg.RefreshTokenTTL)
	}
	if len(cfg.Clients) != 3 {
		t.Errorf("expected 3 clients, got %d", len(cfg.Clients))
	}
}

func TestLoad_MissingRequired(t *testing.T) {
	setValidEnv(t)
	t.Setenv("JWT_PRIVATE_KEY", "")
	t.Setenv("CLIENT_FIELD_SECRET", "")
	t.Setenv("REDIS_ADDR", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error for missing env")
	}
	for _, key := range []string{"JWT_PRIVATE_KEY", "CLIENT_FIELD_SECRET", "REDIS_ADDR"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error should mention %s, got: %v", key, err)
		}
	}
}
