package httpclient

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

const CorrelationHeader = "X-Correlation-ID"

type Transport struct {
	base   http.RoundTripper
	log    *slog.Logger
	target string
}

func NewTransport(base http.RoundTripper, log *slog.Logger, target string) *Transport {
	if base == nil {
		base = http.DefaultTransport
	}
	return &Transport{base: base, log: log, target: target}
}

func (t *Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	ctx := req.Context()
	out := req.Clone(ctx)
	if id, ok := ctx.Value(logger.CorrelationKey).(string); ok && id != "" {
		out.Header.Set(CorrelationHeader, id)
	}

	start := time.Now()
	resp, err := t.base.RoundTrip(out)
	duration := time.Since(start).Milliseconds()

	if err != nil {
		t.log.WarnContext(ctx, "outbound_call",
			"target", t.target,
			"method", out.Method,
			"path", out.URL.Path,
			"duration_ms", duration,
			"error", err.Error(),
		)
		return nil, err
	}

	t.log.InfoContext(ctx, "outbound_call",
		"target", t.target,
		"method", out.Method,
		"path", out.URL.Path,
		"status", resp.StatusCode,
		"duration_ms", duration,
	)
	return resp, nil
}
