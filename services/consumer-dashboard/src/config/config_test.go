package config_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/config"
)

func setValidEnv(t *testing.T) {
	t.Setenv("RABBITMQ_URL", "amqp://user:pass@message-broker:5672/")
}

func TestLoad_Defaults(t *testing.T) {
	setValidEnv(t)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != "8085" {
		t.Errorf("expected port 8085, got %s", cfg.Port)
	}
	if cfg.ExchangeName != "hazard.events" {
		t.Errorf("expected exchange hazard.events, got %s", cfg.ExchangeName)
	}
	if cfg.QueueName != "dashboard" {
		t.Errorf("expected queue dashboard, got %s", cfg.QueueName)
	}
	if !reflect.DeepEqual(cfg.BindingKeys, []string{"#"}) {
		t.Errorf("expected binding keys [#], got %v", cfg.BindingKeys)
	}
	if cfg.Prefetch != 10 {
		t.Errorf("expected prefetch 10, got %d", cfg.Prefetch)
	}
}

func TestLoad_Overrides(t *testing.T) {
	setValidEnv(t)
	t.Setenv("PORT", "8087")
	t.Setenv("QUEUE_NAME", "portal-pemda")
	t.Setenv("BINDING_KEYS", " volcanic , seismic,, ")
	t.Setenv("PREFETCH", "1")

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != "8087" || cfg.QueueName != "portal-pemda" || cfg.Prefetch != 1 {
		t.Errorf("overrides not applied: %+v", cfg)
	}
	if !reflect.DeepEqual(cfg.BindingKeys, []string{"volcanic", "seismic"}) {
		t.Errorf("expected binding keys trimmed and empty entries dropped, got %v", cfg.BindingKeys)
	}
}

func TestLoad_MissingRequired(t *testing.T) {
	t.Setenv("RABBITMQ_URL", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error for missing env")
	}
	if !strings.Contains(err.Error(), "RABBITMQ_URL") {
		t.Errorf("error should mention RABBITMQ_URL, got: %v", err)
	}
}

func TestLoad_InvalidValues(t *testing.T) {
	cases := map[string][2]string{
		"non-amqp scheme":    {"RABBITMQ_URL", "http://message-broker:5672/"},
		"missing host":       {"RABBITMQ_URL", "amqp://"},
		"only empty binding": {"BINDING_KEYS", " , "},
		"zero prefetch":      {"PREFETCH", "0"},
		"negative prefetch":  {"PREFETCH", "-5"},
	}
	for name, kv := range cases {
		t.Run(name, func(t *testing.T) {
			setValidEnv(t)
			t.Setenv(kv[0], kv[1])

			if _, err := config.Load(); err == nil {
				t.Fatalf("expected error for %s=%q", kv[0], kv[1])
			}
		})
	}
}
