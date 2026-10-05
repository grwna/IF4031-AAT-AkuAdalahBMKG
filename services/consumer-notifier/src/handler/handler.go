package handler

import (
	"encoding/json"
	"net/http"
)

type BrokerStatus interface {
	Connected() bool
}

type healthResponse struct {
	Status       string            `json:"status"`
	Service      string            `json:"service"`
	Dependencies map[string]string `json:"dependencies"`
}

type Handler struct {
	service string
	broker  BrokerStatus
}

func New(service string, broker BrokerStatus) *Handler {
	return &Handler{service: service, broker: broker}
}

func (h *Handler) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.Health)
	return mux
}

func (h *Handler) Health(w http.ResponseWriter, _ *http.Request) {
	resp := healthResponse{Status: "UP", Service: h.service, Dependencies: map[string]string{"broker": "UP"}}
	if !h.broker.Connected() {
		resp.Status = "DEGRADED"
		resp.Dependencies["broker"] = "DOWN"
	}
	writeJSON(w, http.StatusOK, resp)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
