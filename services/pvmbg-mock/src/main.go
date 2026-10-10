package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func main() {
	log := logger.NewJSONLogger()

	cfg, err := config.LoadConfig()
	if err != nil {
		log.Error("failed to load configuration, rejecting launch", "error", err)
		os.Exit(1)
	}

	st := store.NewMemoryStore()
	generator.Seed(st, 20)
	log.Info("PVMBG mock initialized with 20 seeded records")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pvmbgHandler := handler.NewPVMBGHandler(st, cfg.BearerToken, cfg.MinDelayMS, cfg.MaxDelayMS, log)
	generator.Start(ctx, st, pvmbgHandler.SchemaConfidence(), time.Duration(cfg.EventIntervalSec)*time.Second, log)
	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: pvmbgHandler.Routes(),
	}

	go func() {
		log.Info("PVMBG mock service listening", "port", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("server error", "error", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Info("shutting down PVMBG mock service")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	server.Shutdown(shutdownCtx)
}
