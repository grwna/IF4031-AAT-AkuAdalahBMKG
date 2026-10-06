package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/polling"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

type Server struct {
	store       *store.PostgresStore
	tracker     *polling.StatusTracker
	logger      *slog.Logger
	router      *http.ServeMux
	handler     http.Handler
	rateLimiter chan struct{} // Semaphore channel untuk mengendalikan jumlah request bersamaan (Problem 2)
}

func NewServer(store *store.PostgresStore, tracker *polling.StatusTracker, l *slog.Logger, maxConcurrent int) *Server {
	if maxConcurrent <= 0 {
		maxConcurrent = 100
	}
	s := &Server{
		store:       store,
		tracker:     tracker,
		logger:      l,
		router:      http.NewServeMux(),
		rateLimiter: make(chan struct{}, maxConcurrent),
	}
	s.routes()
	s.handler = middleware.CorrelationIDMiddleware(s.router)
	return s
}

// Setup rute API menggunakan Go 1.22 ServeMux (dukungan method & path wildcard)
func (s *Server) routes() {
	s.router.HandleFunc("GET /health", s.handleHealth)
	s.router.HandleFunc("GET /internal/source-status", s.handleSourceStatus)
	s.router.HandleFunc("GET /internal/hazards", s.handleGetHazards)
	s.router.HandleFunc("GET /internal/hazards/{hazard_id}", s.handleGetHazardByID)
}

// ServeHTTP dengan Concurrency Limiter (429 Overload Protection) & Correlation ID middleware
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// 1. Proteksi Overload (Problem 2 Poin 11): Kembalikan HTTP 429 jika batas request bersamaan terlampaui
	select {
	case s.rateLimiter <- struct{}{}:
		defer func() { <-s.rateLimiter }()
	default:
		s.writeJSONError(w, http.StatusTooManyRequests, "TOO_MANY_REQUESTS", "Server sedang mengalami beban tinggi (overload)")
		return
	}

	w.Header().Set("Content-Type", "application/json")

	// 2. Menggunakan CorrelationIDMiddleware dari shared/middleware
	s.handler.ServeHTTP(w, r)
}

// Helper untuk mengirimkan respons JSON error standar (§2)
func (s *Server) writeJSONError(w http.ResponseWriter, statusCode int, errCode, message string) {
	w.WriteHeader(statusCode)
	resp := domain.APIErrorResponse{
		Error: domain.APIError{
			Code:    errCode,
			Message: message,
		},
	}
	_ = json.NewEncoder(w).Encode(resp)
}

// Handler GET /health
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":  "UP",
		"service": "aggregator",
	})
}

// Handler GET /internal/source-status (§4.3)
func (s *Server) handleSourceStatus(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"source_status": s.tracker.GetStatus(),
	})
}

// Handler GET /internal/hazards (§4.1)
func (s *Server) handleGetHazards(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()

	// 1. Parse Limit
	limit := 50
	if lStr := query.Get("limit"); lStr != "" {
		parsedLimit, err := strconv.Atoi(lStr)
		if err != nil || parsedLimit < 1 || parsedLimit > 200 {
			s.writeJSONError(w, http.StatusBadRequest, "INVALID_PARAMETER", "limit harus berupa angka 1-200")
			return
		}
		limit = parsedLimit
	}

	// 2. Parse Severity (dipisahkan koma, mis. SIAGA,AWAS)
	var severityList []string
	if sevStr := query.Get("severity"); sevStr != "" {
		for _, part := range strings.Split(sevStr, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				severityList = append(severityList, trimmed)
			}
		}
	}

	// 3. Parse Since (RFC3339)
	var sinceTime time.Time
	if sinceStr := query.Get("since"); sinceStr != "" {
		t, err := time.Parse(time.RFC3339, sinceStr)
		if err != nil {
			s.writeJSONError(w, http.StatusBadRequest, "INVALID_PARAMETER", "since harus berformat RFC3339 (contoh: 2026-10-01T10:15:02Z)")
			return
		}
		sinceTime = t
	}

	// 4. Parse Until (RFC3339)
	var untilTime time.Time
	if untilStr := query.Get("until"); untilStr != "" {
		t, err := time.Parse(time.RFC3339, untilStr)
		if err != nil {
			s.writeJSONError(w, http.StatusBadRequest, "INVALID_PARAMETER", "until harus berformat RFC3339 (contoh: 2026-10-01T10:15:02Z)")
			return
		}
		untilTime = t
	}

	filter := store.FilterParams{
		Type:     query.Get("type"),
		Source:   query.Get("source"),
		Severity: severityList,
		Since:    sinceTime,
		Until:    untilTime,
		Limit:    limit,
		Cursor:   query.Get("cursor"),
	}

	events, nextCursor, err := s.store.GetHazards(r.Context(), filter)
	if err != nil {
		if err.Error() == "INVALID_CURSOR" {
			s.writeJSONError(w, http.StatusBadRequest, "INVALID_PARAMETER", "cursor tidak valid atau rusak")
			return
		}
		s.logger.Error("Gagal mengambil hazards dari store", slog.String("error", err.Error()))
		s.writeJSONError(w, http.StatusServiceUnavailable, "STORE_UNAVAILABLE", "Canonical store tidak terjangkau")
		return
	}

	if events == nil {
		events = []domain.HazardEvent{}
	}

	var nextCursorPtr *string
	if nextCursor != "" {
		nextCursorPtr = &nextCursor
	}

	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"data":          events,
		"next_cursor":   nextCursorPtr,
		"source_status": s.tracker.GetStatus(),
	})
}

// Handler GET /internal/hazards/{hazard_id} (§4.2)
func (s *Server) handleGetHazardByID(w http.ResponseWriter, r *http.Request) {
	hazardID := r.PathValue("hazard_id")
	if hazardID == "" {
		s.writeJSONError(w, http.StatusBadRequest, "INVALID_PARAMETER", "hazard_id tidak boleh kosong")
		return
	}

	event, err := s.store.GetHazardByID(r.Context(), hazardID)
	if err != nil {
		s.logger.Error("Gagal mengambil hazard by ID dari store", slog.String("hazard_id", hazardID), slog.String("error", err.Error()))
		s.writeJSONError(w, http.StatusServiceUnavailable, "STORE_UNAVAILABLE", "Canonical store tidak terjangkau")
		return
	}

	if event == nil {
		s.writeJSONError(w, http.StatusNotFound, "NOT_FOUND", "hazard_id tidak ditemukan")
		return
	}

	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"data":          event,
		"source_status": s.tracker.GetStatus(),
	})
}
