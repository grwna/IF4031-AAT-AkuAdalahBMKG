package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/clients"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/service"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/token"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func main() {
	log := logger.NewJSONLogger()

	cfg, err := config.Load()
	if err != nil {
		log.Error("failed to load configuration, rejecting launch", "error", err)
		os.Exit(1)
	}

	key, err := token.ParsePrivateKey(cfg.PrivateKey)
	if err != nil {
		log.Error("invalid JWT_PRIVATE_KEY", "error", err)
		os.Exit(1)
	}

	registry, err := clients.NewRegistry(cfg.Clients)
	if err != nil {
		log.Error("invalid client configuration", "error", err)
		os.Exit(1)
	}

	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
	defer rdb.Close()

	pingCtx, pingCancel := context.WithTimeout(context.Background(), 2*time.Second)
	if err := rdb.Ping(pingCtx).Err(); err != nil {
		log.Warn("redis not reachable at startup, will keep retrying per request", "addr", cfg.RedisAddr, "error", err)
	}
	pingCancel()

	issuer := token.NewIssuer(key, cfg.Issuer, cfg.Audience, cfg.AccessTokenTTL)
	svc := service.New(registry, issuer, store.NewRedisStore(rdb), cfg.RefreshTokenTTL, log)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler.New(svc, log).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Info("auth-service listening", "port", cfg.Port, "access_ttl", cfg.AccessTokenTTL.String(), "refresh_ttl", cfg.RefreshTokenTTL.String())
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Info("shutting down auth-service")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
	}
}
