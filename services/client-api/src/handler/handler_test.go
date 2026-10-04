package handler_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/aggclient"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/auth"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/concurrency"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/handler"
)

const (
	issuer   = "bnpb-auth-service"
	audience = "bnpb-client-api"
)

const seismic = `{"hazard_id":"BMKG-bmkg-0021","source":"BMKG","source_ref_id":"bmkg-0021","hazard_type":"SEISMIC","severity":"SIAGA","area_name":"Sulawesi Tengah","latitude":-0.89,"longitude":119.87,"occurred_at":"2026-10-01T10:14:55Z","ingested_at":"2026-10-01T10:14:58Z","attributes":{"magnitude":6.8}}`

const volcanic = `{"hazard_id":"PVMBG-pvmbg-0034","source":"PVMBG","source_ref_id":"pvmbg-0034","hazard_type":"VOLCANIC","severity":"WASPADA","area_name":"Gunung Merapi","latitude":-7.5407,"longitude":110.4457,"occurred_at":"2026-10-01T10:15:00Z","ingested_at":"2026-10-01T10:15:03Z","attributes":{"confidence_level":0.87}}`

const sourceStatus = `{"BMKG":{"status":"UP"},"PVMBG":{"status":"DEGRADED","stale_since":"2026-10-01T10:15:02Z"}}`

type fakeAggregator struct {
	hits      atomic.Int32
	mode      string
	gate      chan struct{}
	mu        sync.Mutex
	lastQuery string
	lastCorr  string
}

func (f *fakeAggregator) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/health" {
		if f.mode == "down" {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"status":"UP","service":"aggregator"}`))
		return
	}

	f.hits.Add(1)
	f.mu.Lock()
	f.lastQuery = r.URL.RawQuery
	f.lastCorr = r.Header.Get("X-Correlation-ID")
	f.mu.Unlock()
	if f.gate != nil {
		<-f.gate
	}

	switch f.mode {
	case "down":
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":"STORE_UNAVAILABLE","message":"store down"}}`))
		return
	case "badrequest":
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":"INVALID_PARAMETER","message":"since must be RFC3339"}}`))
		return
	}

	switch r.URL.Path {
	case "/internal/hazards":
		_, _ = w.Write([]byte(`{"data":[` + seismic + `,` + volcanic + `],"next_cursor":"abc","source_status":` + sourceStatus + `}`))
	case "/internal/hazards/BMKG-bmkg-0021":
		_, _ = w.Write([]byte(`{"data":` + seismic + `,"source_status":` + sourceStatus + `}`))
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"NOT_FOUND","message":"not found"}}`))
	}
}

type env struct {
	t    *testing.T
	priv ed25519.PrivateKey
	agg  *fakeAggregator
	h    http.Handler
	logs *bytes.Buffer
}

func newEnv(t *testing.T, maxConcurrent int) *env {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fa := &fakeAggregator{}
	srv := httptest.NewServer(fa)
	t.Cleanup(srv.Close)

	logs := &bytes.Buffer{}
	log := slog.New(slog.NewJSONHandler(&syncWriter{w: logs}, nil))
	h := handler.New(
		aggclient.New(srv.URL, time.Second, log),
		auth.NewVerifier(pub, issuer, audience, 0),
		concurrency.NewLimit(maxConcurrent, log),
		log,
	).Routes()
	return &env{t: t, priv: priv, agg: fa, h: h, logs: logs}
}

type syncWriter struct {
	mu sync.Mutex
	w  *bytes.Buffer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func (e *env) token(sub, scope string) string {
	e.t.Helper()
	now := time.Now()
	c := auth.Claims{
		Scope: scope,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Audience:  jwt.ClaimStrings{audience},
			Subject:   sub,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Minute)),
		},
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodEdDSA, c).SignedString(e.priv)
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

func (e *env) media() string { return e.token("media-client", "hazards:read:summary") }
func (e *env) field() string { return e.token("field-team", "hazards:read:raw") }

func (e *env) get(path, token string, headers ...string) *httptest.ResponseRecorder {
	e.t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("decode body: %v (%s)", err, rec.Body.String())
	}
	return m
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var b struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &b); err != nil {
		t.Fatalf("decode error body: %v (%s)", err, rec.Body.String())
	}
	return b.Error.Code
}

func keysOf(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func listItems(t *testing.T, rec *httptest.ResponseRecorder) []json.RawMessage {
	t.Helper()
	var items []json.RawMessage
	if err := json.Unmarshal(decode(t, rec)["data"], &items); err != nil {
		t.Fatal(err)
	}
	return items
}

var summaryKeys = "area_name,hazard_id,hazard_type,ingested_at,occurred_at,severity,source"
var allKeys = "area_name,attributes,hazard_id,hazard_type,ingested_at,latitude,longitude,occurred_at,severity,source,source_ref_id"

func expectStatus(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d (%s)", rec.Code, status, rec.Body.String())
	}
	if code != "" {
		if got := errorCode(t, rec); got != code {
			t.Errorf("error code = %q, want %q", got, code)
		}
	}
}

func TestList_MediaGetsSummaryOnly(t *testing.T) {
	e := newEnv(t, 10)
	rec := e.get("/hazards", e.media())
	expectStatus(t, rec, http.StatusOK, "")

	for _, item := range listItems(t, rec) {
		if got := strings.Join(keysOf(t, item), ","); got != summaryKeys {
			t.Errorf("media keys = %s, want %s", got, summaryKeys)
		}
	}
	body := decode(t, rec)
	if !strings.Contains(string(body["source_status"]), "stale_since") {
		t.Errorf("source_status not forwarded: %s", body["source_status"])
	}
	if string(body["next_cursor"]) != `"abc"` {
		t.Errorf("next_cursor = %s", body["next_cursor"])
	}
}

func TestList_FieldGetsEverything(t *testing.T) {
	e := newEnv(t, 10)
	rec := e.get("/hazards", e.field())
	expectStatus(t, rec, http.StatusOK, "")

	items := listItems(t, rec)
	for _, item := range items {
		if got := strings.Join(keysOf(t, item), ","); got != allKeys {
			t.Errorf("field keys = %s, want %s", got, allKeys)
		}
	}
	if !strings.Contains(string(items[1]), "confidence_level") {
		t.Errorf("attributes not passed through: %s", items[1])
	}
}

func TestList_ForwardsFiltersAndCorrelationID(t *testing.T) {
	e := newEnv(t, 10)
	rec := e.get("/hazards?type=SEISMIC&fields=severity&debug=1", e.field(), "X-Correlation-ID", "corr-777")
	expectStatus(t, rec, http.StatusOK, "")

	if e.agg.lastQuery != "type=SEISMIC" {
		t.Errorf("forwarded query = %q, want type=SEISMIC", e.agg.lastQuery)
	}
	if e.agg.lastCorr != "corr-777" {
		t.Errorf("aggregator got correlation id %q", e.agg.lastCorr)
	}
	if rec.Header().Get("X-Correlation-ID") != "corr-777" {
		t.Errorf("response correlation id = %q", rec.Header().Get("X-Correlation-ID"))
	}
}

func TestFields(t *testing.T) {
	e := newEnv(t, 10)

	rec := e.get("/hazards?fields=severity,area_name", e.media())
	expectStatus(t, rec, http.StatusOK, "")
	for _, item := range listItems(t, rec) {
		if got := strings.Join(keysOf(t, item), ","); got != "area_name,severity" {
			t.Errorf("selected keys = %s", got)
		}
	}

	rec = e.get("/hazards/BMKG-bmkg-0021?fields=latitude,longitude", e.field())
	expectStatus(t, rec, http.StatusOK, "")
	if got := strings.Join(keysOf(t, decode(t, rec)["data"]), ","); got != "latitude,longitude" {
		t.Errorf("detail selected keys = %s", got)
	}
}

func TestScopeDeniedNeverCallsAggregator(t *testing.T) {
	e := newEnv(t, 10)
	opsOnly := e.token("weird-client", "ops:admin")

	cases := []struct {
		name, path, token string
	}{
		{"media raw field via fields", "/hazards?fields=severity,latitude", e.media()},
		{"media attributes on detail", "/hazards/BMKG-bmkg-0021?fields=attributes", e.media()},
		{"media raw endpoint", "/hazards/BMKG-bmkg-0021/raw", e.media()},
		{"no read scope list", "/hazards", opsOnly},
		{"no read scope detail", "/hazards/BMKG-bmkg-0021", opsOnly},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			before := e.agg.hits.Load()
			expectStatus(t, e.get(tc.path, tc.token), http.StatusForbidden, "INSUFFICIENT_SCOPE")
			if e.agg.hits.Load() != before {
				t.Error("aggregator must not be called when scope is denied")
			}
		})
	}
	if !strings.Contains(e.logs.String(), `"msg":"scope_denied"`) || !strings.Contains(e.logs.String(), `"client_id":"media-client"`) {
		t.Errorf("missing scope_denied log: %s", e.logs.String())
	}
}

func TestInvalidFields(t *testing.T) {
	e := newEnv(t, 10)
	for _, path := range []string{"/hazards?fields=password", "/hazards?fields=", "/hazards?fields=severity,,source"} {
		t.Run(path, func(t *testing.T) {
			expectStatus(t, e.get(path, e.field()), http.StatusBadRequest, "INVALID_PARAMETER")
		})
	}
	if e.agg.hits.Load() != 0 {
		t.Error("aggregator must not be called for invalid fields")
	}
}

func TestRaw_FieldGetsRawView(t *testing.T) {
	e := newEnv(t, 10)
	rec := e.get("/hazards/BMKG-bmkg-0021/raw?fields=severity", e.field())
	expectStatus(t, rec, http.StatusOK, "")
	if got := strings.Join(keysOf(t, decode(t, rec)["data"]), ","); got != "attributes,hazard_id,latitude,longitude,source_ref_id" {
		t.Errorf("raw view keys = %s", got)
	}
}

func TestDetail_MediaSummaryAndNotFound(t *testing.T) {
	e := newEnv(t, 10)
	rec := e.get("/hazards/BMKG-bmkg-0021", e.media())
	expectStatus(t, rec, http.StatusOK, "")
	if got := strings.Join(keysOf(t, decode(t, rec)["data"]), ","); got != summaryKeys {
		t.Errorf("media detail keys = %s", got)
	}

	expectStatus(t, e.get("/hazards/UNKNOWN-1", e.field()), http.StatusNotFound, "NOT_FOUND")
}

func TestAuthRequired(t *testing.T) {
	e := newEnv(t, 10)
	for _, path := range []string{"/hazards", "/hazards/BMKG-bmkg-0021", "/hazards/BMKG-bmkg-0021/raw"} {
		expectStatus(t, e.get(path, ""), http.StatusUnauthorized, "MISSING_TOKEN")
	}
	expectStatus(t, e.get("/hazards", "garbage"), http.StatusUnauthorized, "INVALID_TOKEN")
}

func TestUpstreamErrors(t *testing.T) {
	e := newEnv(t, 10)

	e.agg.mode = "badrequest"
	rec := e.get("/hazards?since=yesterday", e.field())
	expectStatus(t, rec, http.StatusBadRequest, "INVALID_PARAMETER")
	if !strings.Contains(rec.Body.String(), "since must be RFC3339") {
		t.Errorf("aggregator message not forwarded: %s", rec.Body.String())
	}

	e.agg.mode = "down"
	expectStatus(t, e.get("/hazards", e.field()), http.StatusServiceUnavailable, "UPSTREAM_UNAVAILABLE")
	expectStatus(t, e.get("/hazards/BMKG-bmkg-0021", e.media()), http.StatusServiceUnavailable, "UPSTREAM_UNAVAILABLE")
	if !strings.Contains(e.logs.String(), `"msg":"upstream_unavailable"`) {
		t.Errorf("missing upstream_unavailable log")
	}
}

func TestHealth(t *testing.T) {
	e := newEnv(t, 10)

	rec := e.get("/health", "")
	expectStatus(t, rec, http.StatusOK, "")
	if !strings.Contains(rec.Body.String(), `"status":"UP"`) || !strings.Contains(rec.Body.String(), `"aggregator":"UP"`) {
		t.Errorf("unexpected health body: %s", rec.Body.String())
	}

	e.agg.mode = "down"
	rec = e.get("/health", "")
	expectStatus(t, rec, http.StatusOK, "")
	if !strings.Contains(rec.Body.String(), `"status":"DEGRADED"`) || !strings.Contains(rec.Body.String(), `"aggregator":"DOWN"`) {
		t.Errorf("unexpected degraded health body: %s", rec.Body.String())
	}
}

func TestConcurrencyLimitAppliesBeforeAuthAndSkipsHealth(t *testing.T) {
	e := newEnv(t, 1)
	e.agg.gate = make(chan struct{})

	done := make(chan int)
	go func() { done <- e.get("/hazards", e.field()).Code }()
	for e.agg.hits.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}

	expectStatus(t, e.get("/hazards", e.field()), http.StatusTooManyRequests, "TOO_MANY_REQUESTS")
	expectStatus(t, e.get("/hazards", ""), http.StatusTooManyRequests, "TOO_MANY_REQUESTS")
	expectStatus(t, e.get("/health", ""), http.StatusOK, "")

	close(e.agg.gate)
	if code := <-done; code != http.StatusOK {
		t.Errorf("in-flight request got %d", code)
	}
}
