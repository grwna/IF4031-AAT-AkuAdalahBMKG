package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func main() {
	cfg := config.LoadConfig()
	log := logger.NewJSONLogger()

	st := store.NewMemoryStore()
	generator.Seed(st, 20)
	log.Info("BMKG mock initialized with 20 seeded records")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	generator.Start(ctx, st, time.Duration(cfg.EventIntervalSec)*time.Second, log)

	bmkgHandler := handler.NewBMKGHandler(st, cfg.APIKey, cfg.MinDelayMS, cfg.MaxDelayMS, log)
	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: bmkgHandler.Routes(),
	}

	go func() {
		log.Info("BMKG mock service listening", "port", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("server error", "error", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Info("shutting down BMKG mock service")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	server.Shutdown(shutdownCtx)
}
