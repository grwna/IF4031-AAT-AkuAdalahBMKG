package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

type PVMBGHandler struct {
	store            *store.MemoryStore
	bearerToken      string
	minDelayMS       atomic.Int64
	maxDelayMS       atomic.Int64
	schemaConfidence atomic.Bool
	isOutage         atomic.Bool
	logger           *slog.Logger
}

func NewPVMBGHandler(st *store.MemoryStore, token string, minDelay, maxDelay int, log *slog.Logger) *PVMBGHandler {
	h := &PVMBGHandler{
		store:       st,
		bearerToken: token,
		logger:      log,
	}
	h.minDelayMS.Store(int64(minDelay))
	h.maxDelayMS.Store(int64(maxDelay))
	return h
}

func (h *PVMBGHandler) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		parts := strings.SplitN(authHeader, " ", 2)
		if len(parts) != 2 || parts[0] != "Bearer" || parts[1] != h.bearerToken {
			h.logger.WarnContext(r.Context(), "unauthorized PVMBG access attempt", "reason", "invalid token")
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (h *PVMBGHandler) outageMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if h.isOutage.Load() {
			h.logger.WarnContext(r.Context(), "request rejected due to simulated outage")
			http.Error(w, `{"error":"service unavailable (outage simulation)"}`, http.StatusServiceUnavailable)
			return
		}
		next(w, r)
	}
}

func (h *PVMBGHandler) dynamicDelayMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		minMS := int(h.minDelayMS.Load())
		maxMS := int(h.maxDelayMS.Load())
		if maxMS > 0 && maxMS >= minMS {
			delay := minMS
			if maxMS > minMS {
				delay += int(time.Now().UnixNano() % int64(maxMS-minMS))
			}
			time.Sleep(time.Duration(delay) * time.Millisecond)
		}
		next(w, r)
	}
}

func (h *PVMBGHandler) SchemaConfidence() *atomic.Bool {
	return &h.schemaConfidence
}

func (h *PVMBGHandler) GetVolcanicReports(w http.ResponseWriter, r *http.Request) {
	sinceStr := r.URL.Query().Get("since")
	var since time.Time
	if sinceStr != "" {
		parsed, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			since = parsed
		}
	}

	reports := h.store.GetVolcanicReports(since)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(reports)
}

func (h *PVMBGHandler) handleDelayAdmin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		MinDelayMS *int `json:"min_delay_ms"`
		MaxDelayMS *int `json:"max_delay_ms"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
		if body.MinDelayMS != nil {
			h.minDelayMS.Store(int64(*body.MinDelayMS))
		}
		if body.MaxDelayMS != nil {
			h.maxDelayMS.Store(int64(*body.MaxDelayMS))
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":       "ok",
		"min_delay_ms": h.minDelayMS.Load(),
		"max_delay_ms": h.maxDelayMS.Load(),
	})
}

// atomicToggleEndpoint returns an http.HandlerFunc that sets flag from bodyField
// in the JSON body, or toggles it when parsing fails.
// Response: {"status":"ok", responseKey: <current value>}.
func atomicToggleEndpoint(flag *atomic.Bool, bodyField, responseKey string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			if v, ok := body[bodyField].(bool); ok {
				flag.Store(v)
			} else {
				flag.Store(!flag.Load())
			}
		} else {
			flag.Store(!flag.Load())
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":    "ok",
			responseKey: flag.Load(),
		})
	}
}

func (h *PVMBGHandler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"UP","service":"PVMBG"}`))
}

func (h *PVMBGHandler) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", h.HealthCheck)
	mux.HandleFunc("POST /admin/schema-version", h.authMiddleware(atomicToggleEndpoint(&h.schemaConfidence, "enabled", "confidence_level")))
	mux.HandleFunc("POST /admin/outage", h.authMiddleware(atomicToggleEndpoint(&h.isOutage, "outage", "outage")))
	mux.HandleFunc("POST /admin/delay", h.authMiddleware(h.handleDelayAdmin))
	mux.HandleFunc("GET /volcanic-reports", h.outageMiddleware(h.authMiddleware(h.dynamicDelayMiddleware(h.GetVolcanicReports))))

	return middleware.CorrelationIDMiddleware(middleware.LoggingMiddleware(h.logger)(mux))
}
