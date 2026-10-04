package aggclient_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/aggclient"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

const listBody = `{
	"data": [
		{"hazard_id": "BMKG-bmkg-0021", "severity": "SIAGA", "attributes": {"magnitude": 6.8}},
		{"hazard_id": "PVMBG-pvmbg-0034", "severity": "WASPADA", "attributes": {"confidence_level": 0.87}}
	],
	"next_cursor": null,
	"source_status": {"BMKG": {"status": "UP"}, "PVMBG": {"status": "DEGRADED", "stale_since": "2026-10-01T10:15:02Z"}}
}`

func newClient(t *testing.T, h http.HandlerFunc, timeout time.Duration) *aggclient.Client {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return aggclient.New(srv.URL, timeout, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)))
}

func TestListHazards_Success(t *testing.T) {
	var gotPath string
	var gotQuery url.Values
	var gotCorr string
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.Query()
		gotCorr = r.Header.Get("X-Correlation-ID")
		_, _ = w.Write([]byte(listBody))
	}, time.Second)

	in := url.Values{
		"type":     {"SEISMIC"},
		"severity": {"SIAGA,AWAS"},
		"limit":    {"10"},
		"fields":   {"latitude"},
		"debug":    {"true"},
	}
	ctx := context.WithValue(context.Background(), logger.CorrelationKey, "corr-xyz")
	res, err := c.ListHazards(ctx, in)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if gotPath != "/internal/hazards" {
		t.Errorf("path = %q", gotPath)
	}
	want := url.Values{"type": {"SEISMIC"}, "severity": {"SIAGA,AWAS"}, "limit": {"10"}}
	if gotQuery.Encode() != want.Encode() {
		t.Errorf("forwarded query = %q, want %q", gotQuery.Encode(), want.Encode())
	}
	if gotCorr != "corr-xyz" {
		t.Errorf("X-Correlation-ID = %q, want corr-xyz", gotCorr)
	}
	if len(res.Data) != 2 || res.NextCursor != nil {
		t.Errorf("unexpected response: %+v", res)
	}
	if !strings.Contains(string(res.Data[1]["attributes"]), "confidence_level") {
		t.Errorf("attributes not passed through: %s", res.Data[1]["attributes"])
	}
	if !strings.Contains(string(res.SourceStatus), "stale_since") {
		t.Errorf("source_status not passed through: %s", res.SourceStatus)
	}
}

func TestGetHazard_EscapesID(t *testing.T) {
	var gotRawPath string
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotRawPath = r.URL.EscapedPath()
		_, _ = w.Write([]byte(`{"data": {"hazard_id": "x"}, "source_status": {}}`))
	}, time.Second)

	res, err := c.GetHazard(context.Background(), "a/b?c")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotRawPath != "/internal/hazards/a%2Fb%3Fc" {
		t.Errorf("escaped path = %q", gotRawPath)
	}
	if string(res.Data["hazard_id"]) != `"x"` {
		t.Errorf("unexpected data: %v", res.Data)
	}
}

func TestGet_ErrorMapping(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		check  func(t *testing.T, err error)
	}{
		{"not found", 404, `{"error":{"code":"NOT_FOUND","message":"x"}}`, func(t *testing.T, err error) {
			if !errors.Is(err, aggclient.ErrNotFound) {
				t.Errorf("want ErrNotFound, got %v", err)
			}
		}},
		{"bad request with message", 400, `{"error":{"code":"INVALID_PARAMETER","message":"since must be RFC3339"}}`, func(t *testing.T, err error) {
			var br *aggclient.BadRequestError
			if !errors.As(err, &br) || br.Message != "since must be RFC3339" {
				t.Errorf("want BadRequestError with message, got %v", err)
			}
		}},
		{"bad request without body", 400, ``, func(t *testing.T, err error) {
			var br *aggclient.BadRequestError
			if !errors.As(err, &br) || br.Message != "invalid parameter" {
				t.Errorf("want BadRequestError with default message, got %v", err)
			}
		}},
		{"store unavailable", 503, `{"error":{"code":"STORE_UNAVAILABLE","message":"x"}}`, func(t *testing.T, err error) {
			if !errors.Is(err, aggclient.ErrUnavailable) {
				t.Errorf("want ErrUnavailable, got %v", err)
			}
		}},
		{"internal error", 500, `{}`, func(t *testing.T, err error) {
			if !errors.Is(err, aggclient.ErrUnavailable) {
				t.Errorf("want ErrUnavailable, got %v", err)
			}
		}},
		{"malformed 200", 200, `not json`, func(t *testing.T, err error) {
			if !errors.Is(err, aggclient.ErrUnavailable) {
				t.Errorf("want ErrUnavailable, got %v", err)
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newClient(t, func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}, time.Second)
			_, err := c.ListHazards(context.Background(), nil)
			tc.check(t, err)
		})
	}
}

func TestGet_Timeout(t *testing.T) {
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(2 * time.Second):
		case <-r.Context().Done():
		}
	}, 100*time.Millisecond)

	start := time.Now()
	_, err := c.ListHazards(context.Background(), nil)
	if !errors.Is(err, aggclient.ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("timeout not enforced, took %v", elapsed)
	}
}

func TestGet_ConnectionRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	base := srv.URL
	srv.Close()

	c := aggclient.New(base, time.Second, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)))
	if _, err := c.GetHazard(context.Background(), "x"); !errors.Is(err, aggclient.ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
	if err := c.Health(context.Background()); !errors.Is(err, aggclient.ErrUnavailable) {
		t.Fatalf("health: want ErrUnavailable, got %v", err)
	}
}

func TestHealth_OK(t *testing.T) {
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(`{"status":"UP","service":"aggregator"}`))
	}, time.Second)

	if err := c.Health(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
