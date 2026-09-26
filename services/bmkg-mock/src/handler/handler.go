package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

type BMKGHandler struct {
	store      *store.MemoryStore
	apiKey     string
	minDelayMS int
	maxDelayMS int
	logger     *slog.Logger
}

func NewBMKGHandler(st *store.MemoryStore, apiKey string, minDelay, maxDelay int, log *slog.Logger) *BMKGHandler {
	return &BMKGHandler{
		store:      st,
		apiKey:     apiKey,
		minDelayMS: minDelay,
		maxDelayMS: maxDelay,
		logger:     log,
	}
}

func (h *BMKGHandler) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("X-BMKG-Key")
		if key == "" || key != h.apiKey {
			h.logger.WarnContext(r.Context(), "unauthorized access attempt", "provided_key", key)
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (h *BMKGHandler) GetSeismicEvents(w http.ResponseWriter, r *http.Request) {
	sinceStr := r.URL.Query().Get("since")
	var since time.Time
	if sinceStr != "" {
		parsed, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			since = parsed
		}
	}

	events := h.store.GetSeismicEvents(since)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(events)
}

func (h *BMKGHandler) GetTsunamiWarnings(w http.ResponseWriter, r *http.Request) {
	sinceStr := r.URL.Query().Get("since")
	var since time.Time
	if sinceStr != "" {
		parsed, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			since = parsed
		}
	}

	warnings := h.store.GetTsunamiWarnings(since)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(warnings)
}

func (h *BMKGHandler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"UP","service":"BMKG"}`))
}

func (h *BMKGHandler) Routes() http.Handler {
	mux := http.NewServeMux()

	delay := middleware.DelayMiddleware(h.minDelayMS, h.maxDelayMS)
	mux.HandleFunc("GET /health", h.HealthCheck)
	mux.HandleFunc("GET /seismic-events", h.authMiddleware(delay(h.GetSeismicEvents)))
	mux.HandleFunc("GET /tsunami-warnings", h.authMiddleware(delay(h.GetTsunamiWarnings)))

	return middleware.CorrelationIDMiddleware(middleware.LoggingMiddleware(h.logger)(mux))
}
