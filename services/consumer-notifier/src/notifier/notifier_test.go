package notifier_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/broker"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/event"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/idempotency"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/notifier"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func newHandler(buf *bytes.Buffer) broker.HandlerFunc {
	log := slog.New(&logger.ContextHandler{Handler: slog.NewJSONHandler(buf, nil)})
	return notifier.Handle(idempotency.NewMemory(), log, "notifier")
}

func message(messageID string) broker.Message {
	return broker.Message{
		Event:       event.HazardEvent{HazardID: "BMKG-bmkg-0021", Severity: "SIAGA"},
		MessageID:   messageID,
		RoutingKey:  "seismic",
		Redelivered: false,
	}
}

func TestHandle_FirstDeliveryNotifies(t *testing.T) {
	var buf bytes.Buffer
	h := newHandler(&buf)

	if err := h(context.Background(), message("BMKG-bmkg-0021:SIAGA")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"msg":"notification_sent"`) {
		t.Errorf("expected notification_sent log, got %s", out)
	}
	if !strings.Contains(out, `"duplicate":false`) {
		t.Errorf("expected duplicate=false on first delivery, got %s", out)
	}
	if strings.Contains(out, "notification_skipped_duplicate") {
		t.Errorf("first delivery must not be skipped, got %s", out)
	}
}

func TestHandle_DuplicateDeliveryIsSkipped(t *testing.T) {
	var buf bytes.Buffer
	h := newHandler(&buf)
	msg := message("BMKG-bmkg-0021:SIAGA")

	if err := h(context.Background(), msg); err != nil {
		t.Fatalf("first delivery: %v", err)
	}
	if err := h(context.Background(), msg); err != nil {
		t.Fatalf("second delivery: %v", err)
	}

	out := buf.String()
	if got := strings.Count(out, `"msg":"notification_sent"`); got != 1 {
		t.Errorf("expected exactly 1 notification_sent, got %d in %s", got, out)
	}
	if !strings.Contains(out, `"msg":"notification_skipped_duplicate"`) {
		t.Errorf("expected notification_skipped_duplicate log, got %s", out)
	}
	if !strings.Contains(out, `"duplicate":true`) {
		t.Errorf("expected duplicate=true on second delivery, got %s", out)
	}
}

func TestHandle_SeverityChangeNotifiesAgain(t *testing.T) {
	var buf bytes.Buffer
	h := newHandler(&buf)

	if err := h(context.Background(), message("BMKG-bmkg-0021:SIAGA")); err != nil {
		t.Fatalf("siaga delivery: %v", err)
	}
	if err := h(context.Background(), message("BMKG-bmkg-0021:AWAS")); err != nil {
		t.Fatalf("awas delivery: %v", err)
	}

	out := buf.String()
	if got := strings.Count(out, `"msg":"notification_sent"`); got != 2 {
		t.Errorf("a severity change is an update and must notify again, got %d in %s", got, out)
	}
}

func TestHandle_EmptyMessageIDFallsBackToHazardIDSeverity(t *testing.T) {
	var buf bytes.Buffer
	h := newHandler(&buf)
	msg := message("")

	if err := h(context.Background(), msg); err != nil {
		t.Fatalf("first delivery: %v", err)
	}
	if err := h(context.Background(), msg); err != nil {
		t.Fatalf("second delivery: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"idempotency_key":"BMKG-bmkg-0021:SIAGA"`) {
		t.Errorf("expected fallback key hazard_id:severity, got %s", out)
	}
	if got := strings.Count(out, `"msg":"notification_sent"`); got != 1 {
		t.Errorf("fallback key must still dedup, got %d notifications in %s", got, out)
	}
}
