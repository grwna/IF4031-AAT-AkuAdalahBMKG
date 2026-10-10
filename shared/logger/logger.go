package logger

import (
	"context"
	"log/slog"
	"os"
)

type correlationKeyType struct{}

var CorrelationKey = correlationKeyType{}

type ContextHandler struct {
	slog.Handler
}

func (h *ContextHandler) Handle(ctx context.Context, r slog.Record) error {
	if ctx != nil {
		if id, ok := ctx.Value(CorrelationKey).(string); ok && id != "" {
			r.AddAttrs(slog.String("correlation_id", id))
		}
	}
	return h.Handler.Handle(ctx, r)
}

func NewJSONLogger() *slog.Logger {
	baseHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	return slog.New(&ContextHandler{Handler: baseHandler})
}

// FromContext mengembalikan correlation_id dari context jika ada
func FromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	if id, ok := ctx.Value(CorrelationKey).(string); ok {
		return id
	}
	return ""
}
