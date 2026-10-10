package notifier

import (
	"context"
	"log/slog"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/broker"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/idempotency"
)

// Handle return broker handler. Emit notification exactly once per key
// Key = AMQP message_id (<hazard_id>:<severity>). 
// If missing, fall back to <hazard_id>:<severity> from event. 
// Duplicate deliveries ack, no re-notify.
func Handle(store idempotency.Store, log *slog.Logger, queue string) broker.HandlerFunc {
	return func(ctx context.Context, msg broker.Message) error {
		key := msg.MessageID
		if key == "" {
			key = msg.Event.HazardID + ":" + msg.Event.Severity
		}

		if !store.MarkIfNew(key) {
			log.InfoContext(ctx, "notification_skipped_duplicate",
				"queue", queue,
				"idempotency_key", key,
				"hazard_id", msg.Event.HazardID,
				"severity", msg.Event.Severity,
				"message_id", msg.MessageID,
				"routing_key", msg.RoutingKey,
				"redelivered", msg.Redelivered,
				"duplicate", true,
			)
			return nil
		}

		log.InfoContext(ctx, "notification_sent",
			"queue", queue,
			"idempotency_key", key,
			"hazard_id", msg.Event.HazardID,
			"severity", msg.Event.Severity,
			"message_id", msg.MessageID,
			"routing_key", msg.RoutingKey,
			"redelivered", msg.Redelivered,
			"duplicate", false,
		)
		return nil
	}
}
