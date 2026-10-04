package aggclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/httpclient"
)

const maxResponseBytes = 8 << 20

var (
	ErrNotFound    = errors.New("hazard not found")
	ErrUnavailable = errors.New("aggregator unavailable")
)

type BadRequestError struct {
	Message string
}

func (e *BadRequestError) Error() string {
	return "aggregator rejected request: " + e.Message
}

var ListParams = []string{"type", "source", "severity", "since", "until", "limit", "cursor"}

type ListResponse struct {
	Data         []map[string]json.RawMessage `json:"data"`
	NextCursor   *string                      `json:"next_cursor"`
	SourceStatus json.RawMessage              `json:"source_status"`
}

type DetailResponse struct {
	Data         map[string]json.RawMessage `json:"data"`
	SourceStatus json.RawMessage            `json:"source_status"`
}

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type Client struct {
	baseURL string
	http    *http.Client
}

func New(baseURL string, timeout time.Duration, log *slog.Logger) *Client {
	return &Client{
		baseURL: baseURL,
		http: &http.Client{
			Timeout:   timeout,
			Transport: httpclient.NewTransport(nil, log, "aggregator"),
		},
	}
}

func (c *Client) ListHazards(ctx context.Context, query url.Values) (*ListResponse, error) {
	forwarded := url.Values{}
	for _, k := range ListParams {
		if vs, ok := query[k]; ok {
			forwarded[k] = vs
		}
	}
	var out ListResponse
	if err := c.get(ctx, "/internal/hazards", forwarded, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) GetHazard(ctx context.Context, id string) (*DetailResponse, error) {
	var out DetailResponse
	if err := c.get(ctx, "/internal/hazards/"+url.PathEscape(id), nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Health(ctx context.Context) error {
	return c.get(ctx, "/health", nil, nil)
}

func (c *Client) get(ctx context.Context, path string, query url.Values, out any) error {
	target := c.baseURL + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()
	body := io.LimitReader(resp.Body, maxResponseBytes)

	switch resp.StatusCode {
	case http.StatusOK:
		if out == nil {
			return nil
		}
		if err := json.NewDecoder(body).Decode(out); err != nil {
			return fmt.Errorf("%w: invalid response body: %v", ErrUnavailable, err)
		}
		return nil
	case http.StatusNotFound:
		return ErrNotFound
	case http.StatusBadRequest:
		var eb errorBody
		msg := "invalid parameter"
		if json.NewDecoder(body).Decode(&eb) == nil && eb.Error.Message != "" {
			msg = eb.Error.Message
		}
		return &BadRequestError{Message: msg}
	default:
		return fmt.Errorf("%w: status %d", ErrUnavailable, resp.StatusCode)
	}
}
