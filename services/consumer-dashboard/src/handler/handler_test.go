package handler_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-dashboard/src/handler"
)

type fakeBroker bool

func (f fakeBroker) Connected() bool { return bool(f) }

type healthBody struct {
	Status       string            `json:"status"`
	Service      string            `json:"service"`
	Dependencies map[string]string `json:"dependencies"`
}

func getHealth(t *testing.T, connected bool) (*httptest.ResponseRecorder, healthBody) {
	t.Helper()
	h := handler.New("consumer-dashboard", fakeBroker(connected))
	rec := httptest.NewRecorder()
	h.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	var body healthBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("invalid json body: %v (%s)", err, rec.Body.String())
	}
	return rec, body
}

func TestHealth_Connected(t *testing.T) {
	rec, body := getHealth(t, true)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected application/json, got %q", ct)
	}
	if body.Status != "UP" || body.Service != "consumer-dashboard" || body.Dependencies["broker"] != "UP" {
		t.Errorf("unexpected body: %+v", body)
	}
}

func TestHealth_DisconnectedIsDegradedButStill200(t *testing.T) {
	rec, body := getHealth(t, false)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 while degraded, got %d", rec.Code)
	}
	if body.Status != "DEGRADED" || body.Dependencies["broker"] != "DOWN" {
		t.Errorf("unexpected body: %+v", body)
	}
}

func TestRoutes_UnknownPathAndMethod(t *testing.T) {
	h := handler.New("consumer-dashboard", fakeBroker(true))

	rec := httptest.NewRecorder()
	h.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/events", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("expected 404 for unknown path, got %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	h.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/health", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 for POST /health, got %d", rec.Code)
	}
}
