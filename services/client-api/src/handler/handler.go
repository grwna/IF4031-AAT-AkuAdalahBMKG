package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/aggclient"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/apierror"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/auth"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/concurrency"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/scope"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

const healthTimeout = time.Second

type listResponse struct {
	Data         []map[string]json.RawMessage `json:"data"`
	NextCursor   *string                      `json:"next_cursor"`
	SourceStatus json.RawMessage              `json:"source_status"`
}

type detailResponse struct {
	Data         map[string]json.RawMessage `json:"data"`
	SourceStatus json.RawMessage            `json:"source_status"`
}

type healthResponse struct {
	Status       string            `json:"status"`
	Service      string            `json:"service"`
	Dependencies map[string]string `json:"dependencies"`
}

type Handler struct {
	agg      *aggclient.Client
	verifier *auth.Verifier
	limit    *concurrency.Limit
	log      *slog.Logger
}

func New(agg *aggclient.Client, verifier *auth.Verifier, limit *concurrency.Limit, log *slog.Logger) *Handler {
	return &Handler{agg: agg, verifier: verifier, limit: limit, log: log}
}

func (h *Handler) Routes() http.Handler {
	protect := func(f http.HandlerFunc) http.Handler {
		return h.limit.Middleware(auth.Middleware(h.verifier, h.log)(f))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.Health)
	mux.Handle("GET /hazards", protect(h.ListHazards))
	mux.Handle("GET /hazards/{id}", protect(h.GetHazard))
	mux.Handle("GET /hazards/{id}/raw", protect(h.GetHazardRaw))
	return middleware.CorrelationIDMiddleware(middleware.LoggingMiddleware(h.log)(mux))
}

func (h *Handler) ListHazards(w http.ResponseWriter, r *http.Request) {
	access, fields, ok := h.authorize(w, r, true, nil)
	if !ok {
		return
	}

	res, err := h.agg.ListHazards(r.Context(), r.URL.Query())
	if err != nil {
		h.writeUpstreamError(w, r, err)
		return
	}

	data := make([]map[string]json.RawMessage, len(res.Data))
	for i, ev := range res.Data {
		data[i] = scope.Project(ev, access, fields)
	}
	writeJSON(w, http.StatusOK, listResponse{Data: data, NextCursor: res.NextCursor, SourceStatus: res.SourceStatus})
}

func (h *Handler) GetHazard(w http.ResponseWriter, r *http.Request) {
	access, fields, ok := h.authorize(w, r, true, nil)
	if !ok {
		return
	}
	h.writeDetail(w, r, access, fields)
}

func (h *Handler) GetHazardRaw(w http.ResponseWriter, r *http.Request) {
	access, fields, ok := h.authorize(w, r, false, scope.RawViewFields)
	if !ok {
		return
	}
	h.writeDetail(w, r, access, fields)
}

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
	defer cancel()

	resp := healthResponse{Status: "UP", Service: "client-api", Dependencies: map[string]string{"aggregator": "UP"}}
	if err := h.agg.Health(ctx); err != nil {
		h.log.WarnContext(r.Context(), "aggregator_health_failed", "error", err.Error())
		resp.Status = "DEGRADED"
		resp.Dependencies["aggregator"] = "DOWN"
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handler) authorize(w http.ResponseWriter, r *http.Request, allowFieldsParam bool, fixed []string) (scope.Access, []string, bool) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		h.log.ErrorContext(r.Context(), "request_error", "error", "claims missing from context")
		apierror.Write(w, http.StatusInternalServerError, apierror.CodeInternalError, "internal server error")
		return scope.AccessNone, nil, false
	}
	access := scope.AccessFor(claims)

	fields := fixed
	if allowFieldsParam && r.URL.Query().Has("fields") {
		parsed, err := scope.ParseFields(r.URL.Query().Get("fields"))
		if err != nil {
			apierror.Write(w, http.StatusBadRequest, apierror.CodeInvalidParameter, err.Error())
			return scope.AccessNone, nil, false
		}
		fields = parsed
	}

	if err := scope.Authorize(access, fields); err != nil {
		h.log.WarnContext(r.Context(), "scope_denied",
			"client_id", claims.Subject,
			"path", r.URL.Path,
			"raw_fields", scope.RawFieldsIn(fields),
		)
		apierror.Write(w, http.StatusForbidden, apierror.CodeInsufficientScope, err.Error())
		return scope.AccessNone, nil, false
	}
	return access, fields, true
}

func (h *Handler) writeDetail(w http.ResponseWriter, r *http.Request, access scope.Access, fields []string) {
	res, err := h.agg.GetHazard(r.Context(), r.PathValue("id"))
	if err != nil {
		h.writeUpstreamError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, detailResponse{Data: scope.Project(res.Data, access, fields), SourceStatus: res.SourceStatus})
}

func (h *Handler) writeUpstreamError(w http.ResponseWriter, r *http.Request, err error) {
	var badReq *aggclient.BadRequestError
	switch {
	case errors.Is(err, aggclient.ErrNotFound):
		apierror.Write(w, http.StatusNotFound, apierror.CodeNotFound, "hazard not found")
	case errors.As(err, &badReq):
		apierror.Write(w, http.StatusBadRequest, apierror.CodeInvalidParameter, badReq.Message)
	case errors.Is(err, aggclient.ErrUnavailable):
		h.log.ErrorContext(r.Context(), "upstream_unavailable", "target", "aggregator", "error", err.Error())
		apierror.Write(w, http.StatusServiceUnavailable, apierror.CodeUpstreamUnavailable, "hazard data temporarily unavailable")
	default:
		h.log.ErrorContext(r.Context(), "request_error", "error", err.Error())
		apierror.Write(w, http.StatusInternalServerError, apierror.CodeInternalError, "internal server error")
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
