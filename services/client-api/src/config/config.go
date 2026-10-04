package config

import (
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"
)

type Config struct {
	Port                  string
	PublicKey             string
	Issuer                string
	Audience              string
	Leeway                time.Duration
	AggregatorURL         string
	AggregatorTimeout     time.Duration
	MaxConcurrentRequests int
}

func Load() (Config, error) {
	var missing []string
	required := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
		}
		return v
	}

	cfg := Config{
		Port:                  envutil.Str("PORT", "8080"),
		PublicKey:             required("JWT_PUBLIC_KEY"),
		Issuer:                envutil.Str("JWT_ISSUER", "bnpb-auth-service"),
		Audience:              envutil.Str("JWT_AUDIENCE", "bnpb-client-api"),
		Leeway:                time.Duration(envutil.Int("JWT_LEEWAY_SECONDS", 0)) * time.Second,
		AggregatorURL:         strings.TrimRight(required("AGGREGATOR_URL"), "/"),
		AggregatorTimeout:     time.Duration(envutil.Int("AGGREGATOR_TIMEOUT_MS", 2000)) * time.Millisecond,
		MaxConcurrentRequests: envutil.Int("MAX_CONCURRENT_REQUESTS", 100),
	}

	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required env: %s", strings.Join(missing, ", "))
	}
	if u, err := url.Parse(cfg.AggregatorURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return Config{}, fmt.Errorf("AGGREGATOR_URL must be an absolute http(s) URL")
	}
	if cfg.Leeway < 0 {
		return Config{}, fmt.Errorf("JWT_LEEWAY_SECONDS must not be negative")
	}
	if cfg.AggregatorTimeout <= 0 {
		return Config{}, fmt.Errorf("AGGREGATOR_TIMEOUT_MS must be positive")
	}
	if cfg.MaxConcurrentRequests <= 0 {
		return Config{}, fmt.Errorf("MAX_CONCURRENT_REQUESTS must be positive")
	}
	return cfg, nil
}
