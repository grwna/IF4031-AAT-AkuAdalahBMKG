package config

import (
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"
)

type Config struct {
	Port         string
	RabbitMQURL  string
	ExchangeName string
	QueueName    string
	BindingKeys  []string
	Prefetch     int
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
		Port:         envutil.Str("PORT", "8085"),
		RabbitMQURL:  required("RABBITMQ_URL"),
		ExchangeName: envutil.Str("EXCHANGE_NAME", "hazard.events"),
		QueueName:    envutil.Str("QUEUE_NAME", "dashboard"),
		BindingKeys:  splitList(envutil.Str("BINDING_KEYS", "#")),
		Prefetch:     envutil.Int("PREFETCH", 10),
	}

	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required env: %s", strings.Join(missing, ", "))
	}
	if u, err := url.Parse(cfg.RabbitMQURL); err != nil || (u.Scheme != "amqp" && u.Scheme != "amqps") || u.Host == "" {
		return Config{}, fmt.Errorf("RABBITMQ_URL must be an absolute amqp(s) URL")
	}
	if len(cfg.BindingKeys) == 0 {
		return Config{}, fmt.Errorf("BINDING_KEYS must contain at least one key")
	}
	if cfg.Prefetch <= 0 {
		return Config{}, fmt.Errorf("PREFETCH must be positive")
	}
	return cfg, nil
}

func splitList(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
