package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/api"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/polling"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/publisher"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/envutil"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func main() {
	// 1. Inisialisasi JSON logger terstruktur (dengan dukungan Correlation ID)
	l := logger.NewJSONLogger()
	slog.SetDefault(l)

	l.Info("Memulai Aggregator Service...")

	// 2. Membaca konfigurasi dari variabel lingkungan (environment variables)
	port := envutil.Str("PORT", "")
	dbURL := envutil.Str("DATABASE_URL", "")
	bmkgURL := envutil.Str("BMKG_URL", "")
	bmkgKey := envutil.Str("BMKG_API_KEY", "")
	pvmbgURL := envutil.Str("PVMBG_URL", "")
	pvmbgToken := envutil.Str("PVMBG_TOKEN", "")
	pollIntervalStr := envutil.Str("POLL_INTERVAL", "")
	rabbitURL := envutil.Str("RABBITMQ_URL", "")
	exchangeName := envutil.Str("EXCHANGE_NAME", "hazard.events")

	pollInterval, err := time.ParseDuration(pollIntervalStr)
	if err != nil {
		pollInterval = 3 * time.Second
	}

	// 3. Inisialisasi koneksi ke Canonical Store (PostgreSQL)
	pgStore, err := store.NewPostgresStore(dbURL)
	if err != nil {
		l.Error("Gagal terhubung ke Canonical Store", slog.String("error", err.Error()))
		os.Exit(1)
	}
	defer pgStore.Close() // defer -> memastikan koneksi ditutup saat program selesai  | biar clean
	l.Info("Terhubung ke Canonical Store PostgreSQL")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 4. Inisialisasi Publisher RabbitMQ
	pub := publisher.NewPublisher(rabbitURL, exchangeName, l)
	go pub.StartLoop(ctx) // dia pegang ctx --> start go routine buat publish ke rabbitmq, dia bakal jalan terus sampe ctx cancel

	// 5. Inisialisasi Status Tracker in-memory
	tracker := polling.NewStatusTracker()

	// 6. Inisialisasi & jalankan Poller background (BMKG & PVMBG)
	poller := polling.NewPoller(pgStore, tracker, l, pub, bmkgURL, bmkgKey, pvmbgURL, pvmbgToken, pollInterval)
	go poller.Start(ctx) // dia pegang ctx --> start go routine buat polling ke bmkg & pvmbg, dia bakal jalan terus sampe ctx cancel

	maxConcurrent := envutil.Int("MAX_CONCURRENT_REQUESTS", 100)

	// 6. Inisialisasi HTTP Server dengan Overload Concurrency Limiter
	server := api.NewServer(pgStore, tracker, l, maxConcurrent)
	httpServer := &http.Server{
		Addr:         ":" + port,
		Handler:      server,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	// 7. Channel untuk menangkap sinyal OS shutdown (SIGINT / SIGTERM)
	// untuk handle graceful shutdown -> dari interupt OS ato perintah kill kubernetes -> biar defer nya jalan
	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	// Jalankan HTTP Server di goroutine terpisah
	go func() {
		l.Info(fmt.Sprintf("HTTP Server Aggregator berjalan pada port :%s", port))
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			l.Error("HTTP server error", slog.String("error", err.Error()))
			stopChan <- syscall.SIGTERM // contoh: kalau ada error di server, kita kirim sinyal ke stopChan biar shutdown
		}
	}()

	// 8. Menunggu sinyal shutdown (Graceful Shutdown)
	<-stopChan
	l.Info("Menghentikan service aggregator secara graceful...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		l.Error("Gagal menghentikan HTTP server", slog.String("error", err.Error()))
	}

	l.Info("Service Aggregator berhasil dihentikan secara bersih.")
}
