package handler_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/clients"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/service"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/token"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func setup(t *testing.T) (http.Handler, *miniredis.Miniredis) {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	registry, err := clients.NewRegistry([]config.ClientConfig{
		{ID: "field-team", Secret: "field-secret", Scope: "hazards:read:raw"},
	})
	if err != nil {
		t.Fatalf("registry: %v", err)
	}

	mr := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { client.Close() })

	log := logger.NewJSONLogger()
	issuer := token.NewIssuer(priv, "bnpb-auth-service", "bnpb-client-api", time.Minute)
	svc := service.New(registry, issuer, store.NewRedisStore(client), time.Hour, log)
	return handler.New(svc, log).Routes(), mr
}

func do(t *testing.T, h http.Handler, method, path, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("response is not JSON: %q", rec.Body.String())
	}
	return rec, out
}

func login(t *testing.T, h http.Handler) map[string]any {
	t.Helper()
	rec, body := do(t, h, http.MethodPost, "/token",
		`{"grant_type":"client_credentials","client_id":"field-team","client_secret":"field-secret"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("login: status %d, body %v", rec.Code, body)
	}
	return body
}

func expectError(t *testing.T, rec *httptest.ResponseRecorder, body map[string]any, code int, errCode string) {
	t.Helper()
	if rec.Code != code || body["error"] != errCode {
		t.Fatalf("expected %d %s, got %d %v", code, errCode, rec.Code, body)
	}
}

func TestToken_Success(t *testing.T) {
	h, _ := setup(t)
	req := httptest.NewRequest(http.MethodPost, "/token",
		strings.NewReader(`{"grant_type":"client_credentials","client_id":"field-team","client_secret":"field-secret"}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Error("token response must not be cached")
	}
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["token_type"] != "Bearer" || body["expires_in"] != float64(60) || body["refresh_expires_in"] != float64(3600) {
		t.Errorf("unexpected body: %v", body)
	}
	if body["access_token"] == "" || body["refresh_token"] == "" || body["scope"] != "hazards:read:raw" {
		t.Errorf("missing token fields: %v", body)
	}
}

func TestToken_Errors(t *testing.T) {
	h, _ := setup(t)
	cases := []struct {
		name    string
		body    string
		code    int
		errCode string
	}{
		{"invalid json", `{`, 400, "invalid_request"},
		{"wrong grant type", `{"grant_type":"password","client_id":"field-team","client_secret":"field-secret"}`, 400, "unsupported_grant_type"},
		{"missing secret", `{"grant_type":"client_credentials","client_id":"field-team"}`, 400, "invalid_request"},
		{"wrong secret", `{"grant_type":"client_credentials","client_id":"field-team","client_secret":"nope"}`, 401, "invalid_client"},
		{"unknown client", `{"grant_type":"client_credentials","client_id":"ghost","client_secret":"nope"}`, 401, "invalid_client"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec, body := do(t, h, http.MethodPost, "/token", tc.body)
			expectError(t, rec, body, tc.code, tc.errCode)
		})
	}
}

func TestRefresh_RotateAndReuse(t *testing.T) {
	h, _ := setup(t)
	r1 := login(t, h)["refresh_token"].(string)

	rec, body := do(t, h, http.MethodPost, "/refresh", `{"refresh_token":"`+r1+`"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("refresh: status %d, body %v", rec.Code, body)
	}
	r2 := body["refresh_token"].(string)
	if r2 == r1 {
		t.Fatal("refresh should rotate the token")
	}

	rec, body = do(t, h, http.MethodPost, "/refresh", `{"refresh_token":"`+r1+`"}`)
	expectError(t, rec, body, 401, "invalid_grant")

	rec, body = do(t, h, http.MethodPost, "/refresh", `{"refresh_token":"`+r2+`"}`)
	expectError(t, rec, body, 401, "invalid_grant")
}

func TestRefresh_MissingToken(t *testing.T) {
	h, _ := setup(t)
	rec, body := do(t, h, http.MethodPost, "/refresh", `{}`)
	expectError(t, rec, body, 400, "invalid_request")
}

func TestRedisDown(t *testing.T) {
	h, mr := setup(t)
	r1 := login(t, h)["refresh_token"].(string)
	mr.Close()

	rec, body := do(t, h, http.MethodPost, "/token",
		`{"grant_type":"client_credentials","client_id":"field-team","client_secret":"field-secret"}`)
	expectError(t, rec, body, 503, "temporarily_unavailable")

	rec, body = do(t, h, http.MethodPost, "/refresh", `{"refresh_token":"`+r1+`"}`)
	expectError(t, rec, body, 503, "temporarily_unavailable")

	rec, body = do(t, h, http.MethodGet, "/health", "")
	if rec.Code != http.StatusServiceUnavailable || body["status"] != "DEGRADED" {
		t.Fatalf("health: %d %v", rec.Code, body)
	}
}

func TestHealth_Up(t *testing.T) {
	h, _ := setup(t)
	rec, body := do(t, h, http.MethodGet, "/health", "")
	if rec.Code != http.StatusOK || body["status"] != "UP" {
		t.Fatalf("health: %d %v", rec.Code, body)
	}
	if deps, _ := body["dependencies"].(map[string]any); deps["redis"] != "UP" {
		t.Fatalf("redis dependency: %v", body["dependencies"])
	}
}

func TestCorrelationIDEchoed(t *testing.T) {
	h, _ := setup(t)
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("X-Correlation-ID", "test-corr-123")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("X-Correlation-ID"); got != "test-corr-123" {
		t.Fatalf("expected correlation id echoed, got %q", got)
	}
}
