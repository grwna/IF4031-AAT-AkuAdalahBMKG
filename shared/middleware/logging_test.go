package middleware_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
	"log/slog"
)

func TestLoggingMiddleware_CapturesStatus(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	rec := httptest.NewRecorder()

	handler := middleware.LoggingMiddleware(log)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestLoggingMiddleware_CapturesCustomStatus(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	rec := httptest.NewRecorder()

	handler := middleware.LoggingMiddleware(log)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestLoggingMiddleware_LogsJSONRecord(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	req := httptest.NewRequest(http.MethodGet, "/api/test", nil)
	rec := httptest.NewRecorder()

	handler := middleware.LoggingMiddleware(log)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	handler.ServeHTTP(rec, req)

	var recMap map[string]any
	if err := json.Unmarshal(buf.Bytes(), &recMap); err != nil {
		t.Fatalf("failed to parse log output: %v", err)
	}
	if recMap["level"] != "INFO" {
		t.Fatalf("expected level INFO, got %s", recMap["level"])
	}
	if recMap["msg"] != "request" {
		t.Fatalf("expected msg 'request', got %s", recMap["msg"])
	}
	if recMap["method"] != "GET" {
		t.Fatalf("expected method GET, got %s", recMap["method"])
	}
	if recMap["path"] != "/api/test" {
		t.Fatalf("expected path /api/test, got %s", recMap["path"])
	}
	if recMap["status"] != float64(http.StatusCreated) {
		t.Fatalf("expected status 201, got %v", recMap["status"])
	}
	if _, ok := recMap["duration_ms"]; !ok {
		t.Fatal("expected duration_ms in log record")
	}
}

func TestLoggingMiddleware_CorrelationIDFromContext(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(&logger.ContextHandler{Handler: slog.NewJSONHandler(&buf, nil)})

	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	req = req.WithContext(context.WithValue(req.Context(), logger.CorrelationKey, "test-corr-123"))
	rec := httptest.NewRecorder()

	handler := middleware.LoggingMiddleware(log)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if buf.Len() == 0 {
		t.Fatal("expected log output, got empty")
	}
}
