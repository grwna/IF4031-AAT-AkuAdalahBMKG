package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/polling"
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
