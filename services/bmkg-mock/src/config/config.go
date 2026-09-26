package config

import "github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"

type Config struct {
	Port             string
	APIKey           string
	MinDelayMS       int
	MaxDelayMS       int
	EventIntervalSec int
}

func LoadConfig() Config {
	return Config{
		Port:             envutil.Str("PORT", "8081"),
		APIKey:           envutil.Str("BMKG_API_KEY", "bmkg-secret-key"),
		MinDelayMS:       envutil.Int("BMKG_MIN_DELAY_MS", 50),
		MaxDelayMS:       envutil.Int("BMKG_MAX_DELAY_MS", 150),
		EventIntervalSec: envutil.Int("BMKG_EVENT_INTERVAL_SEC", 10),
	}
}
