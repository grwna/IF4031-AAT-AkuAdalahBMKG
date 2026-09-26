package handler_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func setupTestServer() (http.Handler, *store.MemoryStore, string) {
	st := store.NewMemoryStore()
	generator.Seed(st, 5)
	log := logger.NewJSONLogger()
	apiKey := "secret-bmkg-key-123"

	h := handler.NewBMKGHandler(st, apiKey, 0, 0, log)
	return h.Routes(), st, apiKey
}

func TestBMKG_AuthRejection(t *testing.T) {
	router, _, _ := setupTestServer()

	req := httptest.NewRequest(http.MethodGet, "/seismic-events", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("expected 401 or 403 on missing key, got %d", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/seismic-events", nil)
	req.Header.Set("X-BMKG-Key", "invalid-key")
	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("expected 401 or 403 on invalid key, got %d", rec.Code)
	}
}

func TestBMKG_GetSeismicEvents_Success(t *testing.T) {
	router, _, apiKey := setupTestServer()

	req := httptest.NewRequest(http.MethodGet, "/seismic-events", nil)
	req.Header.Set("X-BMKG-Key", apiKey)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", rec.Code)
	}

	var events []models.SeismicEvent
	if err := json.NewDecoder(rec.Body).Decode(&events); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if len(events) < 5 {
		t.Fatalf("expected at least 5 events, got %d", len(events))
	}
}

func TestBMKG_Health(t *testing.T) {
	router, _, _ := setupTestServer()

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK for health, got %d", rec.Code)
	}
}
