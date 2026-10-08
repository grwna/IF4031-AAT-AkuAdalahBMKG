package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/polling"
	sharedlogger "github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func TestHealthEndpoint(t *testing.T) {
	tracker := polling.NewStatusTracker()
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	server := NewServer(nil, tracker, logger, 100)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	server.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status code 200, got %d", rec.Code)
	}

	var resp map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}

	if resp["status"] != "UP" {
		t.Errorf("expected status UP, got %s", resp["status"])
	}
	if resp["service"] != "aggregator" {
		t.Errorf("expected service aggregator, got %s", resp["service"])
	}
}

func TestSourceStatusEndpoint(t *testing.T) {
	tracker := polling.NewStatusTracker()
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	server := NewServer(nil, tracker, logger, 100)

	req := httptest.NewRequest(http.MethodGet, "/internal/source-status", nil)
	rec := httptest.NewRecorder()

	server.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status code 200, got %d", rec.Code)
	}

	var resp map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}

	if _, ok := resp["source_status"]; !ok {
		t.Errorf("expected source_status field in response, got %v", resp)
	}
}

func TestRateLimiter(t *testing.T) {
	tracker := polling.NewStatusTracker()
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	// Set maxConcurrent = 1 for testing rate limiting
	server := NewServer(nil, tracker, logger, 1)

	// Block the rate limiter channel manually to simulate active request
	server.rateLimiter <- struct{}{}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	server.ServeHTTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("expected status code 429 (Too Many Requests), got %d", rec.Code)
	}

	// Unblock rate limiter channel
	<-server.rateLimiter
}

func TestRequestLoggingWithCorrelationID(t *testing.T) {
	var buf bytes.Buffer
	baseHandler := slog.NewJSONHandler(&buf, nil)
	logger := slog.New(&sharedlogger.ContextHandler{Handler: baseHandler})
	tracker := polling.NewStatusTracker()
	server := NewServer(nil, tracker, logger, 100)

	req := httptest.NewRequest(http.MethodGet, "/internal/source-status", nil)
	req.Header.Set("X-Correlation-ID", "test-corr-123")
	rec := httptest.NewRecorder()

	server.ServeHTTP(rec, req)

	if rec.Header().Get("X-Correlation-ID") != "test-corr-123" {
		t.Errorf("expected X-Correlation-ID test-corr-123, got %s", rec.Header().Get("X-Correlation-ID"))
	}

	logOutput := buf.String()
	if !strings.Contains(logOutput, `"msg":"request"`) {
		t.Errorf("expected request log line, got: %s", logOutput)
	}
	if !strings.Contains(logOutput, `"correlation_id":"test-corr-123"`) {
		t.Errorf("expected correlation_id in log line, got: %s", logOutput)
	}
}
