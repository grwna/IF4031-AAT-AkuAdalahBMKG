package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/apierror"
)

type claimsKeyType struct{}

var claimsKey = claimsKeyType{}

func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(claimsKey).(*Claims)
	return c, ok
}

func WithClaims(ctx context.Context, c *Claims) context.Context {
	return context.WithValue(ctx, claimsKey, c)
}

func Middleware(v *Verifier, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, ok := bearerToken(r)
			if !ok {
				log.WarnContext(r.Context(), "auth_failed", "reason", "missing", "path", r.URL.Path)
				w.Header().Set("WWW-Authenticate", `Bearer`)
				apierror.Write(w, http.StatusUnauthorized, apierror.CodeMissingToken, "bearer token required")
				return
			}

			claims, err := v.Verify(raw)
			if err != nil {
				reason, code, msg := "invalid", apierror.CodeInvalidToken, "invalid access token"
				if errors.Is(err, ErrTokenExpired) {
					reason, code, msg = "expired", apierror.CodeTokenExpired, "access token expired"
				}
				log.WarnContext(r.Context(), "auth_failed", "reason", reason, "path", r.URL.Path, "error", err)
				w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
				apierror.Write(w, http.StatusUnauthorized, code, msg)
				return
			}

			next.ServeHTTP(w, r.WithContext(WithClaims(r.Context(), claims)))
		})
	}
}

func bearerToken(r *http.Request) (string, bool) {
	scheme, token, found := strings.Cut(r.Header.Get("Authorization"), " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}
