package apierror

import (
	"encoding/json"
	"net/http"
)

const (
	CodeMissingToken        = "MISSING_TOKEN"
	CodeInvalidToken        = "INVALID_TOKEN"
	CodeTokenExpired        = "TOKEN_EXPIRED"
	CodeInsufficientScope   = "INSUFFICIENT_SCOPE"
	CodeInvalidParameter    = "INVALID_PARAMETER"
	CodeNotFound            = "NOT_FOUND"
	CodeTooManyRequests     = "TOO_MANY_REQUESTS"
	CodeUpstreamUnavailable = "UPSTREAM_UNAVAILABLE"
	CodeInternalError       = "INTERNAL_ERROR"
)

type detail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type body struct {
	Error detail `json:"error"`
}

func Write(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body{Error: detail{Code: code, Message: message}})
}
