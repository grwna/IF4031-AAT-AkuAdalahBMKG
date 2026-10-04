package httpclient_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/httpclient"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func newLogger(buf *bytes.Buffer) *slog.Logger {
	return slog.New(&logger.ContextHandler{Handler: slog.NewJSONHandler(buf, nil)})
}

func lastLog(t *testing.T, buf *bytes.Buffer) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	var entry map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &entry); err != nil {
		t.Fatalf("decode log: %v (%s)", err, buf.String())
	}
	return entry
}

func TestRoundTrip_PropagatesCorrelationIDAndLogs(t *testing.T) {
	var gotHeader string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeader = r.Header.Get("X-Correlation-ID")
		w.WriteHeader(http.StatusTeapot)
	}))
	defer srv.Close()

	buf := &bytes.Buffer{}
	client := &http.Client{Transport: httpclient.NewTransport(nil, newLogger(buf), "aggregator")}

	ctx := context.WithValue(context.Background(), logger.CorrelationKey, "corr-123")
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/internal/hazards?token=secret", nil)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = resp.Body.Close()

	if gotHeader != "corr-123" {
		t.Errorf("upstream got X-Correlation-ID %q, want corr-123", gotHeader)
	}
	if req.Header.Get("X-Correlation-ID") != "" {
		t.Error("original request must not be modified")
	}

	entry := lastLog(t, buf)
	want := map[string]any{
		"msg":            "outbound_call",
		"level":          "INFO",
		"target":         "aggregator",
		"method":         "GET",
		"path":           "/internal/hazards",
		"status":         float64(http.StatusTeapot),
		"correlation_id": "corr-123",
	}
	for k, v := range want {
		if entry[k] != v {
			t.Errorf("log %s = %v, want %v", k, entry[k], v)
		}
	}
	if _, ok := entry["duration_ms"].(float64); !ok {
		t.Errorf("log missing numeric duration_ms: %v", entry)
	}
	if strings.Contains(buf.String(), "secret") {
		t.Error("query string must not be logged")
	}
}

func TestRoundTrip_NoCorrelationIDInContext(t *testing.T) {
	var gotHeader = "unset"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeader = r.Header.Get("X-Correlation-ID")
	}))
	defer srv.Close()

	client := &http.Client{Transport: httpclient.NewTransport(nil, newLogger(&bytes.Buffer{}), "bmkg")}
	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = resp.Body.Close()

	if gotHeader != "" {
		t.Errorf("expected no X-Correlation-ID header, got %q", gotHeader)
	}
}

func TestRoundTrip_ErrorIsLoggedAndReturned(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close()

	buf := &bytes.Buffer{}
	client := &http.Client{Transport: httpclient.NewTransport(nil, newLogger(buf), "pvmbg")}
	_, err := client.Get(url + "/volcanic-reports")
	if err == nil {
		t.Fatal("expected error from closed server")
	}

	entry := lastLog(t, buf)
	if entry["level"] != "WARN" || entry["target"] != "pvmbg" || entry["path"] != "/volcanic-reports" {
		t.Errorf("unexpected log entry: %v", entry)
	}
	if _, ok := entry["error"].(string); !ok {
		t.Errorf("log missing error: %v", entry)
	}
	if _, ok := entry["status"]; ok {
		t.Errorf("failed call must not log a status: %v", entry)
	}
}
