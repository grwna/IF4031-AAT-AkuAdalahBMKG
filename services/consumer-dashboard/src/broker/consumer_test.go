package broker

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

type fakeAck struct {
	acks    int
	nacks   int
	requeue bool
}

func (f *fakeAck) Ack(uint64, bool) error { f.acks++; return nil }
func (f *fakeAck) Nack(_ uint64, _ bool, requeue bool) error {
	f.nacks++
	f.requeue = requeue
	return nil
}
func (f *fakeAck) Reject(uint64, bool) error { return nil }

const validBody = `{"hazard_id":"BMKG-bmkg-0021","hazard_type":"SEISMIC","severity":"SIAGA","attributes":{"magnitude":6.8}}`

func newTestConsumer(handle HandlerFunc) (*Consumer, *bytes.Buffer) {
	var buf bytes.Buffer
	log := slog.New(&logger.ContextHandler{Handler: slog.NewJSONHandler(&buf, nil)})
	cfg := config.Config{QueueName: "dashboard"}
	return New(cfg, log, handle), &buf
}

func delivery(ack *fakeAck, body, corrID string) amqp.Delivery {
	return amqp.Delivery{
		Acknowledger:  ack,
		DeliveryTag:   1,
		Body:          []byte(body),
		CorrelationId: corrID,
		MessageId:     "BMKG-bmkg-0021:SIAGA",
		RoutingKey:    "seismic",
		Redelivered:   true,
	}
}

func TestProcess_ValidMessageIsHandledThenAcked(t *testing.T) {
	var got Message
	var gotCorrID string
	c, _ := newTestConsumer(func(ctx context.Context, msg Message) error {
		got = msg
		gotCorrID, _ = ctx.Value(logger.CorrelationKey).(string)
		return nil
	})
	ack := &fakeAck{}

	c.process(context.Background(), delivery(ack, validBody, "corr-123"))

	if ack.acks != 1 || ack.nacks != 0 {
		t.Fatalf("expected 1 ack and 0 nack, got %d ack %d nack", ack.acks, ack.nacks)
	}
	if got.Event.HazardID != "BMKG-bmkg-0021" || got.Event.Severity != "SIAGA" {
		t.Errorf("unexpected event passed to handler: %+v", got.Event)
	}
	if string(got.Body) != validBody {
		t.Errorf("expected raw body passed unchanged, got %s", got.Body)
	}
	if got.MessageID != "BMKG-bmkg-0021:SIAGA" || got.RoutingKey != "seismic" || !got.Redelivered {
		t.Errorf("unexpected delivery metadata: %+v", got)
	}
	if gotCorrID != "corr-123" {
		t.Errorf("expected correlation id corr-123 in context, got %q", gotCorrID)
	}
}

func TestProcess_GeneratesCorrelationIDWhenMissing(t *testing.T) {
	var gotCorrID string
	c, _ := newTestConsumer(func(ctx context.Context, _ Message) error {
		gotCorrID, _ = ctx.Value(logger.CorrelationKey).(string)
		return nil
	})

	c.process(context.Background(), delivery(&fakeAck{}, validBody, ""))

	if len(gotCorrID) != 32 {
		t.Errorf("expected generated 32-char correlation id, got %q", gotCorrID)
	}
}

func TestProcess_InvalidMessageIsDroppedWithoutHandling(t *testing.T) {
	called := false
	c, logs := newTestConsumer(func(context.Context, Message) error {
		called = true
		return nil
	})
	ack := &fakeAck{}

	c.process(context.Background(), delivery(ack, `{"hazard_id":`, "corr-bad"))

	if called {
		t.Error("handler must not be called for an invalid message")
	}
	if ack.nacks != 1 || ack.requeue || ack.acks != 0 {
		t.Fatalf("expected nack without requeue, got acks=%d nacks=%d requeue=%v", ack.acks, ack.nacks, ack.requeue)
	}
	out := logs.String()
	if !strings.Contains(out, `"msg":"message_rejected"`) || !strings.Contains(out, `"correlation_id":"corr-bad"`) {
		t.Errorf("expected message_rejected log with correlation id, got %s", out)
	}
}

func TestProcess_HandlerErrorRequeues(t *testing.T) {
	c, logs := newTestConsumer(func(context.Context, Message) error {
		return errors.New("temporary failure")
	})
	ack := &fakeAck{}

	c.process(context.Background(), delivery(ack, validBody, "corr-1"))

	if ack.nacks != 1 || !ack.requeue || ack.acks != 0 {
		t.Fatalf("expected nack with requeue, got acks=%d nacks=%d requeue=%v", ack.acks, ack.nacks, ack.requeue)
	}
	if !strings.Contains(logs.String(), `"msg":"message_requeued"`) {
		t.Errorf("expected message_requeued log, got %s", logs.String())
	}
}
