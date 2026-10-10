package polling

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/httpclient"
	sharedlogger "github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestStatusTracker(t *testing.T) {
	tracker := NewStatusTracker()
	now := time.Now().UTC()

	st := tracker.GetStatus()
	if st[domain.SourceBMKG].Status != domain.SourceStatusUp {
		t.Errorf("expected initial BMKG status UP, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourcePVMBG].Status != domain.SourceStatusUp {
		t.Errorf("expected initial PVMBG status UP, got %s", st[domain.SourcePVMBG].Status)
	}

	tracker.SetSuccess(domain.SourceBMKG, now)
	st = tracker.GetStatus()
	if st[domain.SourceBMKG].LastSuccessAt == nil {
		t.Fatal("expected LastSuccessAt to be set after SetSuccess")
	}
	if !st[domain.SourceBMKG].LastSuccessAt.Equal(now) {
		t.Errorf("expected LastSuccessAt %v, got %v", now, *st[domain.SourceBMKG].LastSuccessAt)
	}

	errMsg := "connection timeout"
	degradedTime := now.Add(5 * time.Second)
	tracker.SetDegraded(domain.SourceBMKG, degradedTime, errMsg)
	st = tracker.GetStatus()

	if st[domain.SourceBMKG].Status != domain.SourceStatusDegraded {
		t.Errorf("expected BMKG status DEGRADED, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourceBMKG].LastError == nil || *st[domain.SourceBMKG].LastError != errMsg {
		t.Errorf("expected LastError %s, got %v", errMsg, st[domain.SourceBMKG].LastError)
	}
	if st[domain.SourceBMKG].StaleSince == nil || !st[domain.SourceBMKG].StaleSince.Equal(now) {
		t.Errorf("expected StaleSince to retain last success time %v, got %v", now, st[domain.SourceBMKG].StaleSince)
	}

	recoverTime := degradedTime.Add(10 * time.Second)
	tracker.SetSuccess(domain.SourceBMKG, recoverTime)
	st = tracker.GetStatus()

	if st[domain.SourceBMKG].Status != domain.SourceStatusUp {
		t.Errorf("expected status UP after recovery, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourceBMKG].StaleSince != nil {
		t.Errorf("expected StaleSince to be nil after recovery, got %v", st[domain.SourceBMKG].StaleSince)
	}
	if st[domain.SourceBMKG].LastError != nil {
		t.Errorf("expected LastError to be nil after recovery, got %v", st[domain.SourceBMKG].LastError)
	}
}

func TestPollerCorrelationIDPropagation(t *testing.T) {
	var bmkgCorrHeader, pvmbgCorrHeader string

	var logBuf bytes.Buffer
	log := slog.New(&sharedlogger.ContextHandler{
		Handler: slog.NewJSONHandler(&logBuf, nil),
	})

	poller := NewPoller(nil, NewStatusTracker(), log, nil, "http://bmkg-mock:8081", "key", "http://pvmbg-mock:8082", "token", time.Second)
	poller.bmkgClient.Transport = httpclient.NewTransport(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		bmkgCorrHeader = r.Header.Get("X-Correlation-ID")
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`[]`)),
		}, nil
	}), log, "bmkg")
	poller.pvmbgClient.Transport = httpclient.NewTransport(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pvmbgCorrHeader = r.Header.Get("X-Correlation-ID")
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`[]`)),
		}, nil
	}), log, "pvmbg")

	poller.pollBMKG(context.Background())
	poller.pollPVMBG(context.Background())

	if !strings.HasPrefix(bmkgCorrHeader, "poller-bmkg-") {
		t.Errorf("expected X-Correlation-ID header with prefix poller-bmkg-, got %q", bmkgCorrHeader)
	}
	if !strings.HasPrefix(pvmbgCorrHeader, "poller-pvmbg-") {
		t.Errorf("expected X-Correlation-ID header with prefix poller-pvmbg-, got %q", pvmbgCorrHeader)
	}

	logs := logBuf.String()
	if !strings.Contains(logs, `"correlation_id":"`+bmkgCorrHeader+`"`) {
		t.Errorf("expected outbound_call log to contain BMKG correlation_id %s, got: %s", bmkgCorrHeader, logs)
	}
	if !strings.Contains(logs, `"correlation_id":"`+pvmbgCorrHeader+`"`) {
		t.Errorf("expected outbound_call log to contain PVMBG correlation_id %s, got: %s", pvmbgCorrHeader, logs)
	}
}

func TestPollerSinceQueryParameter(t *testing.T) {
	var bmkgQueries, pvmbgQueries []string
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))

	poller := NewPoller(nil, NewStatusTracker(), log, nil, "http://bmkg-mock:8081", "key", "http://pvmbg-mock:8082", "token", time.Second)
	poller.bmkgClient.Transport = httpclient.NewTransport(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		bmkgQueries = append(bmkgQueries, r.URL.Query().Get("since"))
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`[]`)),
		}, nil
	}), log, "bmkg")
	poller.pvmbgClient.Transport = httpclient.NewTransport(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pvmbgQueries = append(pvmbgQueries, r.URL.Query().Get("since"))
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`[]`)),
		}, nil
	}), log, "pvmbg")

	// Polling pertama: belum ada LastSuccessAt, sehingga ?since= harus kosong
	poller.pollBMKG(context.Background())
	poller.pollPVMBG(context.Background())

	// Polling kedua: sudah ada LastSuccessAt, sehingga ?since= harus terisi RFC3339
	poller.pollBMKG(context.Background())
	poller.pollPVMBG(context.Background())

	if len(bmkgQueries) != 2 || bmkgQueries[0] != "" || bmkgQueries[1] == "" {
		t.Errorf("expected BMKG since queries [\"\", \"<RFC3339>\"], got %v", bmkgQueries)
	}
	if _, err := time.Parse(time.RFC3339, bmkgQueries[1]); err != nil {
		t.Errorf("expected valid RFC3339 in second BMKG poll, got %q: %v", bmkgQueries[1], err)
	}

	if len(pvmbgQueries) != 2 || pvmbgQueries[0] != "" || pvmbgQueries[1] == "" {
		t.Errorf("expected PVMBG since queries [\"\", \"<RFC3339>\"], got %v", pvmbgQueries)
	}
	if _, err := time.Parse(time.RFC3339, pvmbgQueries[1]); err != nil {
		t.Errorf("expected valid RFC3339 in second PVMBG poll, got %q: %v", pvmbgQueries[1], err)
	}
}
