package broker

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/event"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

const (
	initialBackoff = time.Second
	maxBackoff     = 15 * time.Second
)

type Message struct {
	Event       event.HazardEvent
	Body        json.RawMessage
	MessageID   string
	RoutingKey  string
	Redelivered bool
}

type HandlerFunc func(ctx context.Context, msg Message) error

type Consumer struct {
	cfg       config.Config
	log       *slog.Logger
	handle    HandlerFunc
	connected atomic.Bool
}

func New(cfg config.Config, log *slog.Logger, handle HandlerFunc) *Consumer {
	return &Consumer{cfg: cfg, log: log, handle: handle}
}

func (c *Consumer) Connected() bool {
	return c.connected.Load()
}

func (c *Consumer) Run(ctx context.Context) {
	backoff := initialBackoff
	for {
		wasConnected, err := c.session(ctx)
		if ctx.Err() != nil {
			return
		}
		if wasConnected {
			backoff = initialBackoff
		}
		c.log.WarnContext(ctx, "broker_disconnected",
			"queue", c.cfg.QueueName,
			"error", err.Error(),
			"retry_in_ms", backoff.Milliseconds(),
		)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, maxBackoff)
	}
}

func (c *Consumer) session(ctx context.Context) (bool, error) {
	props := amqp.NewConnectionProperties()
	props.SetClientConnectionName("consumer-" + c.cfg.QueueName)
	conn, err := amqp.DialConfig(c.cfg.RabbitMQURL, amqp.Config{Properties: props})
	if err != nil {
		return false, fmt.Errorf("dial: %w", err)
	}
	defer func() { _ = conn.Close() }()

	ch, err := conn.Channel()
	if err != nil {
		return false, fmt.Errorf("open channel: %w", err)
	}
	defer func() { _ = ch.Close() }()

	if err := c.declareTopology(ch); err != nil {
		return false, err
	}

	deliveries, err := ch.Consume(c.cfg.QueueName, "", false, false, false, false, nil)
	if err != nil {
		return false, fmt.Errorf("consume: %w", err)
	}
	connClosed := conn.NotifyClose(make(chan *amqp.Error, 1))

	c.connected.Store(true)
	defer c.connected.Store(false)
	c.log.InfoContext(ctx, "broker_connected",
		"exchange", c.cfg.ExchangeName,
		"queue", c.cfg.QueueName,
		"binding_keys", c.cfg.BindingKeys,
		"prefetch", c.cfg.Prefetch,
	)

	for {
		select {
		case <-ctx.Done():
			return true, nil
		case amqpErr := <-connClosed:
			return true, fmt.Errorf("connection closed: %v", amqpErr)
		case d, ok := <-deliveries:
			if !ok {
				return true, errors.New("delivery channel closed")
			}
			c.process(ctx, d)
		}
	}
}

func (c *Consumer) declareTopology(ch *amqp.Channel) error {
	if err := ch.Qos(c.cfg.Prefetch, 0, false); err != nil {
		return fmt.Errorf("set qos: %w", err)
	}
	if err := ch.ExchangeDeclare(c.cfg.ExchangeName, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", c.cfg.ExchangeName, err)
	}
	if _, err := ch.QueueDeclare(c.cfg.QueueName, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare queue %s: %w", c.cfg.QueueName, err)
	}
	for _, key := range c.cfg.BindingKeys {
		if err := ch.QueueBind(c.cfg.QueueName, key, c.cfg.ExchangeName, false, nil); err != nil {
			return fmt.Errorf("bind queue %s with key %s: %w", c.cfg.QueueName, key, err)
		}
	}
	return nil
}

func (c *Consumer) process(ctx context.Context, d amqp.Delivery) {
	corrID := d.CorrelationId
	if corrID == "" {
		corrID = newCorrelationID()
	}
	ctx = context.WithValue(ctx, logger.CorrelationKey, corrID)

	ev, err := event.Decode(d.Body)
	if err != nil {
		c.log.ErrorContext(ctx, "message_rejected",
			"queue", c.cfg.QueueName,
			"message_id", d.MessageId,
			"routing_key", d.RoutingKey,
			"body_bytes", len(d.Body),
			"error", err.Error(),
		)
		c.settle(ctx, d, "nack", d.Nack(false, false))
		return
	}

	msg := Message{
		Event:       ev,
		Body:        json.RawMessage(d.Body),
		MessageID:   d.MessageId,
		RoutingKey:  d.RoutingKey,
		Redelivered: d.Redelivered,
	}

	c.log.InfoContext(ctx, "hazard_event_received",
		"queue", c.cfg.QueueName,
		"routing_key", d.RoutingKey,
		"message_id", d.MessageId,
		"redelivered", d.Redelivered,
		"event", msg.Body,
	)

	if err := c.handle(ctx, msg); err != nil {
		c.log.WarnContext(ctx, "message_requeued",
			"queue", c.cfg.QueueName,
			"message_id", d.MessageId,
			"error", err.Error(),
		)
		c.settle(ctx, d, "nack", d.Nack(false, true))
		return
	}
	c.settle(ctx, d, "ack", d.Ack(false))
}

func (c *Consumer) settle(ctx context.Context, d amqp.Delivery, action string, err error) {
	if err != nil {
		c.log.WarnContext(ctx, "message_settle_failed",
			"queue", c.cfg.QueueName,
			"message_id", d.MessageId,
			"action", action,
			"error", err.Error(),
		)
	}
}

func newCorrelationID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "fallback-id"
	}
	return hex.EncodeToString(b)
}
