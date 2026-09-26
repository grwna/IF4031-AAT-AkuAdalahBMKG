package middleware_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

func TestDelayMiddleware_ZeroDelayPassesThrough(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	called := false
	h := middleware.DelayMiddleware(0, 0)(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	h(rec, req)

	if !called {
		t.Fatal("expected inner handler to be called")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestDelayMiddleware_NegativeMaxPassesThrough(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	called := false
	h := middleware.DelayMiddleware(0, -1)(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	h(rec, req)

	if !called {
		t.Fatal("expected inner handler to be called when maxMS <= 0")
	}
}
