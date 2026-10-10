package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/aggclient"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/auth"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/concurrency"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func main() {
	log := logger.NewJSONLogger()

	cfg, err := config.Load()
	if err != nil {
		log.Error("failed to load configuration, rejecting launch", "error", err)
		os.Exit(1)
	}

	key, err := auth.ParsePublicKey(cfg.PublicKey)
	if err != nil {
		log.Error("invalid JWT_PUBLIC_KEY", "error", err)
		os.Exit(1)
	}

	h := handler.New(
		aggclient.New(cfg.AggregatorURL, cfg.AggregatorTimeout, log),
		auth.NewVerifier(key, cfg.Issuer, cfg.Audience, cfg.Leeway),
		concurrency.NewLimit(cfg.MaxConcurrentRequests, log),
		log,
	)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           h.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Info("client-api listening",
			"port", cfg.Port,
			"aggregator_url", cfg.AggregatorURL,
			"aggregator_timeout", cfg.AggregatorTimeout.String(),
			"max_concurrent_requests", cfg.MaxConcurrentRequests,
		)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Info("shutting down client-api")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
	}
}
