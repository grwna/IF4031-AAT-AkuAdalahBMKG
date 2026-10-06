package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/broker"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

const (
	serviceName     = "consumer-dashboard"
	shutdownTimeout = 5 * time.Second
)

func main() {
	log := logger.NewJSONLogger()

	cfg, err := config.Load()
	if err != nil {
		log.Error("failed to load configuration, rejecting launch", "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	consumer := broker.New(cfg, log, logEvent(log, cfg.QueueName))
	consumerDone := make(chan struct{})
	go func() {
		defer close(consumerDone)
		consumer.Run(ctx)
	}()

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler.New(serviceName, consumer).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Info(serviceName+" listening",
			"port", cfg.Port,
			"exchange", cfg.ExchangeName,
			"queue", cfg.QueueName,
			"binding_keys", cfg.BindingKeys,
			"prefetch", cfg.Prefetch,
		)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()

	log.Info("shutting down " + serviceName)
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
	}
	select {
	case <-consumerDone:
	case <-shutdownCtx.Done():
		log.Error("consumer did not stop in time")
	}
}

func logEvent(log *slog.Logger, queue string) broker.HandlerFunc {
	return func(ctx context.Context, msg broker.Message) error {
		log.InfoContext(ctx, "hazard_event_received",
			"queue", queue,
			"routing_key", msg.RoutingKey,
			"message_id", msg.MessageID,
			"redelivered", msg.Redelivered,
			"event", msg.Body,
		)
		return nil
	}
}
