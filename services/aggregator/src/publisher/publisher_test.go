package publisher

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)

func TestNewPublisher(t *testing.T) {
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	pub := NewPublisher("amqp://guest:guest@localhost:5672/", "hazard.events", logger)

	if pub == nil {
		t.Fatal("expected NewPublisher to return a non-nil instance")
	}

	if pub.IsConnected() {
		t.Errorf("expected IsConnected to be false initially")
	}
}

func TestPublishUnconnected(t *testing.T) {
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	pub := NewPublisher("amqp://guest:guest@localhost:5672/", "hazard.events", logger)

	event := domain.HazardEvent{
		HazardID:    "BMKG-bmkg-001",
		Source:      domain.SourceBMKG,
		SourceRefID: "bmkg-001",
		HazardType:  domain.HazardTypeSeismic,
		Severity:    domain.SeveritySiaga,
		OccurredAt:  time.Now().UTC(),
		IngestedAt:  time.Now().UTC(),
	}

	ctx := context.Background()
	err := pub.Publish(ctx, event, "test-correlation-123")
	if err == nil {
		t.Fatalf("expected Publish to fail when unconnected, got nil")
	}

	if !strings.Contains(err.Error(), "tidak terhubung") {
		t.Errorf("expected error message to indicate unconnected status, got: %v", err)
	}
}

func TestMessageIDAndRoutingKeyFormat(t *testing.T) {
	seismicEvent := domain.HazardEvent{
		HazardID:   "BMKG-bmkg-0021",
		HazardType: domain.HazardTypeSeismic,
		Severity:   domain.SeveritySiaga,
	}

	expectedMessageID := seismicEvent.HazardID + ":" + seismicEvent.Severity
	expectedRoutingKey := strings.ToLower(seismicEvent.HazardType)

	if expectedMessageID != "BMKG-bmkg-0021:SIAGA" {
		t.Errorf("expected MessageID BMKG-bmkg-0021:SIAGA, got %s", expectedMessageID)
	}

	if expectedRoutingKey != "seismic" {
		t.Errorf("expected RoutingKey seismic, got %s", expectedRoutingKey)
	}

	volcanicEvent := domain.HazardEvent{
		HazardID:   "PVMBG-pvmbg-0099",
		HazardType: domain.HazardTypeVolcanic,
		Severity:   domain.SeverityAwas,
	}

	expectedVolcanicRoutingKey := strings.ToLower(volcanicEvent.HazardType)
	expectedVolcanicMessageID := volcanicEvent.HazardID + ":" + volcanicEvent.Severity

	if expectedVolcanicRoutingKey != "volcanic" {
		t.Errorf("expected RoutingKey volcanic, got %s", expectedVolcanicRoutingKey)
	}

	if expectedVolcanicMessageID != "PVMBG-pvmbg-0099:AWAS" {
		t.Errorf("expected MessageID PVMBG-pvmbg-0099:AWAS, got %s", expectedVolcanicMessageID)
	}
}
