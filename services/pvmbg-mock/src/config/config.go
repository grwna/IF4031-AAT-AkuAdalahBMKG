package config

import "github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"

type Config struct {
	Port             string
	BearerToken      string
	MinDelayMS       int
	MaxDelayMS       int
	EventIntervalSec int
}

func LoadConfig() Config {
	return Config{
		Port:             envutil.Str("PORT", "8082"),
		BearerToken:      envutil.Str("PVMBG_BEARER_TOKEN", "pvmbg-secret-token"),
		MinDelayMS:       envutil.Int("PVMBG_MIN_DELAY_MS", 500),
		MaxDelayMS:       envutil.Int("PVMBG_MAX_DELAY_MS", 3000),
		EventIntervalSec: envutil.Int("PVMBG_EVENT_INTERVAL_SEC", 10),
	}
}
