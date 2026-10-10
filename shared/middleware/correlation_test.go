package middleware_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

func TestCorrelationIDMiddleware_GeneratesNewID(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	var extractedID string
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		extractedID = middleware.GetCorrelationID(r.Context())
		w.WriteHeader(http.StatusOK)
	})

	handler := middleware.CorrelationIDMiddleware(nextHandler)
	handler.ServeHTTP(rec, req)

	if extractedID == "" {
		t.Fatal("expected correlation ID to be generated in context, got empty string")
	}

	headerID := rec.Header().Get("X-Correlation-ID")
	if headerID != extractedID {
		t.Fatalf("expected response header X-Correlation-ID %s, got %s", extractedID, headerID)
	}
}

func TestCorrelationIDMiddleware_PreservesExistingID(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	expectedID := "test-corr-12345"
	req.Header.Set("X-Correlation-ID", expectedID)
	rec := httptest.NewRecorder()

	var extractedID string
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		extractedID = middleware.GetCorrelationID(r.Context())
		w.WriteHeader(http.StatusOK)
	})

	handler := middleware.CorrelationIDMiddleware(nextHandler)
	handler.ServeHTTP(rec, req)

	if extractedID != expectedID {
		t.Fatalf("expected correlation ID %s, got %s", expectedID, extractedID)
	}
	if rec.Header().Get("X-Correlation-ID") != expectedID {
		t.Fatalf("expected header %s, got %s", expectedID, rec.Header().Get("X-Correlation-ID"))
	}
}
