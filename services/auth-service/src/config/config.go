package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"
)

type ClientConfig struct {
	ID     string
	Secret string
	Scope  string
}

type Config struct {
	Port            string
	PrivateKey      string
	Issuer          string
	Audience        string
	AccessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration
	RedisAddr       string
	Clients         []ClientConfig
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
		Port:            envutil.Str("PORT", "8084"),
		PrivateKey:      required("JWT_PRIVATE_KEY"),
		Issuer:          envutil.Str("JWT_ISSUER", "bnpb-auth-service"),
		Audience:        envutil.Str("JWT_AUDIENCE", "bnpb-client-api"),
		AccessTokenTTL:  time.Duration(envutil.Int("ACCESS_TOKEN_TTL_SECONDS", 60)) * time.Second,
		RefreshTokenTTL: time.Duration(envutil.Int("REFRESH_TOKEN_TTL_SECONDS", 3600)) * time.Second,
		RedisAddr:       required("REDIS_ADDR"),
	}

	for _, prefix := range []string{"CLIENT_MEDIA", "CLIENT_FIELD", "CLIENT_OPS"} {
		cfg.Clients = append(cfg.Clients, ClientConfig{
			ID:     required(prefix + "_ID"),
			Secret: required(prefix + "_SECRET"),
			Scope:  required(prefix + "_SCOPE"),
		})
	}

	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required env: %s", strings.Join(missing, ", "))
	}
	if cfg.AccessTokenTTL <= 0 || cfg.RefreshTokenTTL <= 0 {
		return Config{}, fmt.Errorf("token TTLs must be positive")
	}
	return cfg, nil
}
