package middleware

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func generateRandomID() string {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		return "fallback-id"
	}
	return hex.EncodeToString(b)
}

func CorrelationIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		corrID := r.Header.Get("X-Correlation-ID")
		if corrID == "" {
			corrID = generateRandomID()
		}

		ctx := context.WithValue(r.Context(), logger.CorrelationKey, corrID)
		w.Header().Set("X-Correlation-ID", corrID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// for tests
func GetCorrelationID(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	if id, ok := ctx.Value(logger.CorrelationKey).(string); ok {
		return id
	}
	return ""
}
