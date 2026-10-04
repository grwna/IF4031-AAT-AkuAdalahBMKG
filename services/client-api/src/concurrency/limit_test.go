package concurrency_test

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/concurrency"
)

func serve(h http.Handler) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/hazards", nil))
	return rec
}

func TestLimit_RejectsBeyondCapacityWithoutWaiting(t *testing.T) {
	logs := &bytes.Buffer{}
	release := make(chan struct{})
	entered := make(chan struct{}, 2)
	blocking := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		entered <- struct{}{}
		<-release
		w.WriteHeader(http.StatusOK)
	})
	h := concurrency.NewLimit(2, slog.New(slog.NewJSONHandler(logs, nil))).Middleware(blocking)

	var wg sync.WaitGroup
	codes := make([]int, 2)
	for i := range codes {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i] = serve(h).Code
		}(i)
	}
	<-entered
	<-entered

	start := time.Now()
	rec := serve(h)
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Errorf("rejection should be immediate, took %v", elapsed)
	}
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", rec.Code)
	}
	if rec.Header().Get("Retry-After") != "1" {
		t.Errorf("Retry-After = %q", rec.Header().Get("Retry-After"))
	}
	if !strings.Contains(rec.Body.String(), `"TOO_MANY_REQUESTS"`) {
		t.Errorf("unexpected body: %s", rec.Body.String())
	}
	if !strings.Contains(logs.String(), `"msg":"request_rejected_overload"`) || !strings.Contains(logs.String(), `"limit":2`) {
		t.Errorf("missing overload log: %s", logs.String())
	}

	close(release)
	wg.Wait()
	for i, c := range codes {
		if c != http.StatusOK {
			t.Errorf("in-capacity request %d got %d", i, c)
		}
	}

	if rec := serve(h); rec.Code != http.StatusOK {
		t.Errorf("slot not released after completion, got %d", rec.Code)
	}
}

func TestLimit_ReleasesSlotOnPanic(t *testing.T) {
	panicking := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	})
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	limit := concurrency.NewLimit(1, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)))

	func() {
		defer func() { _ = recover() }()
		serve(limit.Middleware(panicking))
	}()

	if rec := serve(limit.Middleware(ok)); rec.Code != http.StatusOK {
		t.Errorf("slot leaked after panic, got %d", rec.Code)
	}
}
