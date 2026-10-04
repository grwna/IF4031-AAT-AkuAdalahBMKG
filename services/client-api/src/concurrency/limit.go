package concurrency

import (
	"log/slog"
	"net/http"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/apierror"
)

type Limit struct {
	slots chan struct{}
	log   *slog.Logger
}

func NewLimit(max int, log *slog.Logger) *Limit {
	return &Limit{slots: make(chan struct{}, max), log: log}
}

func (l *Limit) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case l.slots <- struct{}{}:
			defer func() { <-l.slots }()
			next.ServeHTTP(w, r)
		default:
			l.log.WarnContext(r.Context(), "request_rejected_overload",
				"path", r.URL.Path,
				"concurrent", len(l.slots),
				"limit", cap(l.slots),
			)
			w.Header().Set("Retry-After", "1")
			apierror.Write(w, http.StatusTooManyRequests, apierror.CodeTooManyRequests, "server is busy, retry later")
		}
	})
}
