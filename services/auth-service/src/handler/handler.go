package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/service"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/middleware"
)

const maxBodyBytes = 1 << 16

type tokenRequest struct {
	GrantType    string `json:"grant_type"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type tokenResponse struct {
	AccessToken      string `json:"access_token"`
	TokenType        string `json:"token_type"`
	ExpiresIn        int    `json:"expires_in"`
	RefreshToken     string `json:"refresh_token"`
	RefreshExpiresIn int    `json:"refresh_expires_in"`
	Scope            string `json:"scope"`
}

type errorResponse struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

type AuthHandler struct {
	svc *service.AuthService
	log *slog.Logger
}

func New(svc *service.AuthService, log *slog.Logger) *AuthHandler {
	return &AuthHandler{svc: svc, log: log}
}

func (h *AuthHandler) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /token", h.Token)
	mux.HandleFunc("POST /refresh", h.Refresh)
	mux.HandleFunc("GET /health", h.Health)
	return middleware.CorrelationIDMiddleware(middleware.LoggingMiddleware(h.log)(mux))
}

func (h *AuthHandler) Token(w http.ResponseWriter, r *http.Request) {
	var req tokenRequest
	if !decode(w, r, &req) {
		return
	}
	if req.GrantType != "client_credentials" {
		writeError(w, http.StatusBadRequest, "unsupported_grant_type", "grant_type must be client_credentials")
		return
	}
	if req.ClientID == "" || req.ClientSecret == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "client_id and client_secret are required")
		return
	}

	pair, err := h.svc.IssueToken(r.Context(), req.ClientID, req.ClientSecret)
	h.respond(w, r, pair, err)
}

func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if !decode(w, r, &req) {
		return
	}
	if req.RefreshToken == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "refresh_token is required")
		return
	}

	pair, err := h.svc.Refresh(r.Context(), req.RefreshToken)
	h.respond(w, r, pair, err)
}

func (h *AuthHandler) Health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()

	status, redisStatus, code := "UP", "UP", http.StatusOK
	if err := h.svc.Ping(ctx); err != nil {
		h.log.ErrorContext(r.Context(), "redis_unavailable", "error", err)
		status, redisStatus, code = "DEGRADED", "DOWN", http.StatusServiceUnavailable
	}

	writeJSON(w, code, map[string]any{
		"status":       status,
		"service":      "auth-service",
		"dependencies": map[string]string{"redis": redisStatus},
	})
}

func (h *AuthHandler) respond(w http.ResponseWriter, r *http.Request, pair service.TokenPair, err error) {
	switch {
	case err == nil:
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Pragma", "no-cache")
		writeJSON(w, http.StatusOK, tokenResponse{
			AccessToken:      pair.AccessToken,
			TokenType:        "Bearer",
			ExpiresIn:        int(pair.AccessTTL.Seconds()),
			RefreshToken:     pair.RefreshToken,
			RefreshExpiresIn: int(pair.RefreshTTL.Seconds()),
			Scope:            pair.Scope,
		})
	case errors.Is(err, service.ErrInvalidClient):
		writeError(w, http.StatusUnauthorized, "invalid_client", "client authentication failed")
	case errors.Is(err, service.ErrInvalidGrant):
		writeError(w, http.StatusUnauthorized, "invalid_grant", "refresh token is invalid, expired, or revoked")
	case errors.Is(err, service.ErrUnavailable):
		h.log.ErrorContext(r.Context(), "redis_unavailable", "error", err)
		writeError(w, http.StatusServiceUnavailable, "temporarily_unavailable", "token store is unavailable, retry later")
	default:
		h.log.ErrorContext(r.Context(), "token_error", "error", err)
		writeError(w, http.StatusInternalServerError, "server_error", "internal error")
	}
}

func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
		return false
	}
	return true
}

func writeError(w http.ResponseWriter, code int, errCode, description string) {
	writeJSON(w, code, errorResponse{Error: errCode, ErrorDescription: description})
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
