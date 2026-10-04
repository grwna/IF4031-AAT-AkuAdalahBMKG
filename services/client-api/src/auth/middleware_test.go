package auth_test

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/auth"
)

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func newProtected(t *testing.T, v *auth.Verifier, logs *bytes.Buffer) http.Handler {
	t.Helper()
	log := slog.New(slog.NewJSONHandler(logs, nil))
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, ok := auth.ClaimsFromContext(r.Context())
		if !ok {
			t.Error("claims missing from context")
		}
		w.Header().Set("X-Subject", c.Subject)
		w.WriteHeader(http.StatusOK)
	})
	return auth.Middleware(v, log)(next)
}

func TestMiddleware_ValidToken(t *testing.T) {
	pub, priv := newKeyPair(t)
	h := newProtected(t, auth.NewVerifier(pub, testIssuer, testAudience, 0), &bytes.Buffer{})

	for _, scheme := range []string{"Bearer", "bearer"} {
		req := httptest.NewRequest(http.MethodGet, "/hazards", nil)
		req.Header.Set("Authorization", scheme+" "+sign(t, priv, validClaims()))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("scheme %q: expected 200, got %d", scheme, rec.Code)
		}
		if rec.Header().Get("X-Subject") != "field-team" {
			t.Errorf("scheme %q: claims not propagated", scheme)
		}
	}
}

func TestMiddleware_Rejections(t *testing.T) {
	pub, priv := newKeyPair(t)
	_, otherPriv := newKeyPair(t)

	expired := validClaims()
	expired.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute))

	cases := []struct {
		name       string
		header     string
		wantCode   string
		wantChal   string
		wantReason string
	}{
		{"no header", "", "MISSING_TOKEN", "Bearer", "missing"},
		{"basic scheme", "Basic dXNlcjpwYXNz", "MISSING_TOKEN", "Bearer", "missing"},
		{"bearer without token", "Bearer ", "MISSING_TOKEN", "Bearer", "missing"},
		{"expired", "Bearer " + sign(t, priv, expired), "TOKEN_EXPIRED", `Bearer error="invalid_token"`, "expired"},
		{"other key", "Bearer " + sign(t, otherPriv, validClaims()), "INVALID_TOKEN", `Bearer error="invalid_token"`, "invalid"},
		{"garbage", "Bearer abc.def.ghi", "INVALID_TOKEN", `Bearer error="invalid_token"`, "invalid"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logs := &bytes.Buffer{}
			h := newProtected(t, auth.NewVerifier(pub, testIssuer, testAudience, 0), logs)

			req := httptest.NewRequest(http.MethodGet, "/hazards", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("expected 401, got %d", rec.Code)
			}
			if got := rec.Header().Get("WWW-Authenticate"); got != tc.wantChal {
				t.Errorf("WWW-Authenticate = %q, want %q", got, tc.wantChal)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q", ct)
			}
			var body errorBody
			if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if body.Error.Code != tc.wantCode {
				t.Errorf("code = %q, want %q", body.Error.Code, tc.wantCode)
			}
			if !strings.Contains(logs.String(), `"reason":"`+tc.wantReason+`"`) {
				t.Errorf("log should contain reason %q, got: %s", tc.wantReason, logs.String())
			}
		})
	}
}

func TestMiddleware_DoesNotLogToken(t *testing.T) {
	pub, _ := newKeyPair(t)
	_, otherPriv := newKeyPair(t)
	logs := &bytes.Buffer{}
	h := newProtected(t, auth.NewVerifier(pub, testIssuer, testAudience, 0), logs)

	token := sign(t, otherPriv, validClaims())
	req := httptest.NewRequest(http.MethodGet, "/hazards", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	h.ServeHTTP(httptest.NewRecorder(), req)

	if strings.Contains(logs.String(), token) {
		t.Error("log must not contain the raw token")
	}
}
