#!/usr/bin/env bash

# ==============================================================================
# Load Testing & Concurrency Benchmark Runner - Problem 2 (IF4031 Milestone 1)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

read_env_var() {
    local file="$1"
    local key="$2"
    local default_val="${3:-}"
    if [[ -f "$file" ]]; then
        local val
        val=$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    echo "$default_val"
}

CLIENT_API_PORT=$(read_env_var "${PROJECT_ROOT}/services/client-api/.env" "PORT" "8080")
AUTH_PORT=$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "PORT" "8084")
PVMBG_PORT=$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PORT" "8082")

CLIENT_API_URL="${CLIENT_API_URL:-http://localhost:${CLIENT_API_PORT}}"
AUTH_URL="${AUTH_URL:-http://localhost:${AUTH_PORT}}"
PVMBG_URL="${PVMBG_URL:-http://localhost:${PVMBG_PORT}}"

CLIENT_OPS_ID="${CLIENT_OPS_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_ID" "bnpb-ops")}"
CLIENT_OPS_SECRET="${CLIENT_OPS_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_SECRET" "")}"
PVMBG_TOKEN="${PVMBG_TOKEN:-$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PVMBG_BEARER_TOKEN" "")}"

VUS="${VUS:-55}"
DURATION_SEC="${DURATION_SEC:-60}"
ENGINE="${ENGINE:-go}" # go | k6 | auto
MODE="${MODE:-both}"   # both | p21 | p22
REPORT_DIR="${PROJECT_ROOT}/scripts/load-test/reports"
SAVE_REPORT="true"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --vus <count>        Number of parallel connections / VUs (default: 55, requirement >= 50)
  -d, --duration <sec>     Sustained load test duration in seconds (default: 60, requirement >= 60)
  -m, --mode <mode>        Test mode: p21 | p22 | both (default: both)
  -e, --engine <mode>      Load test engine: go | k6 | auto (default: go)
  --quick                  Quick mode (55 VUs for 10 seconds)
  --no-save                Do not save report to file
  -h, --help               Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--vus)
            VUS="$2"
            shift 2
            ;;
        -d|--duration)
            DURATION_SEC="${2%s}"
            shift 2
            ;;
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -e|--engine)
            ENGINE="$2"
            shift 2
            ;;
        --quick)
            DURATION_SEC="10"
            shift
            ;;
        --no-save)
            SAVE_REPORT="false"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ "$SAVE_REPORT" == "true" ]]; then
    mkdir -p "$REPORT_DIR"
    TS=$(date +"%Y%m%d-%H%M%S")
    REPORT_FILE="${REPORT_DIR}/load-test-${VUS}vus-${DURATION_SEC}s-${TS}.log"
    exec > >(tee "$REPORT_FILE") 2>&1
fi

curl -s -X POST "${PVMBG_URL}/admin/outage" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${PVMBG_TOKEN}" \
     -d '{"outage": false}' > /dev/null 2>&1 || true

if ! curl -s -f "${CLIENT_API_URL}/health" > /dev/null; then
    echo "Error: Client-Facing API (${CLIENT_API_URL}/health) is unreachable."
    exit 1
fi

SELECTED_ENGINE="$ENGINE"
if [[ "$SELECTED_ENGINE" == "auto" ]]; then
    if command -v k6 &> /dev/null; then
        SELECTED_ENGINE="k6"
    else
        SELECTED_ENGINE="go"
    fi
fi

if [[ "$SELECTED_ENGINE" == "k6" ]]; then
    CLIENT_API_URL="$CLIENT_API_URL" \
    AUTH_URL="$AUTH_URL" \
    CLIENT_ID="$CLIENT_OPS_ID" \
    CLIENT_SECRET="$CLIENT_OPS_SECRET" \
    VUS="$VUS" \
    DURATION="${DURATION_SEC}s" \
    k6 run "${SCRIPT_DIR}/k6-sustained.js"
    exit 0
fi

TMP_GO_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_GO_DIR"' EXIT

cat << 'EOF' > "${TMP_GO_DIR}/main.go"
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type tokenResp struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
}

type sample struct {
	durationMs float64
	statusCode int
	bmkgOnly   bool
}

func fetchToken(client *http.Client, authURL, clientID, clientSecret string) (string, error) {
	body, _ := json.Marshal(map[string]string{
		"grant_type":    "client_credentials",
		"client_id":     clientID,
		"client_secret": clientSecret,
	})
	resp, err := client.Post(authURL+"/token", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, string(b))
	}
	var tr tokenResp
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", err
	}
	return tr.AccessToken, nil
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil((p/100.0)*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func avg(vals []float64) float64 {
	if len(vals) == 0 {
		return 0
	}
	var sum float64
	for _, v := range vals {
		sum += v
	}
	return sum / float64(len(vals))
}

func round2(v float64) float64 {
	return math.Round(v*100) / 100
}

func round4(v float64) float64 {
	return math.Round(v*10000) / 10000
}

func main() {
	apiURL := os.Getenv("CLIENT_API_URL")
	authURL := os.Getenv("AUTH_URL")
	pvmbgURL := os.Getenv("PVMBG_URL")
	pvmbgToken := os.Getenv("PVMBG_TOKEN")
	clientID := os.Getenv("CLIENT_ID")
	clientSecret := os.Getenv("CLIENT_SECRET")
	mode := os.Getenv("MODE")
	if mode == "" {
		mode = "both"
	}
	vus, _ := strconv.Atoi(os.Getenv("VUS"))
	if vus <= 0 {
		vus = 55
	}
	durSec, _ := strconv.Atoi(os.Getenv("DURATION_SEC"))
	if durSec <= 0 {
		durSec = 60
	}

	httpClient := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        vus * 4,
			MaxIdleConnsPerHost: vus * 4,
			MaxConnsPerHost:     vus * 4,
			IdleConnTimeout:     60 * time.Second,
		},
	}

	var tokenVal atomic.Value
	initialTok, err := fetchToken(httpClient, authURL, clientID, clientSecret)
	if err != nil {
		fmt.Printf("Failed to fetch initial token: %v\n", err)
		os.Exit(1)
	}
	tokenVal.Store(initialTok)

	stopRefresh := make(chan struct{})
	go func() {
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-stopRefresh:
				return
			case <-ticker.C:
				if newTok, err := fetchToken(httpClient, authURL, clientID, clientSecret); err == nil && newTok != "" {
					tokenVal.Store(newTok)
				}
			}
		}
	}()

	if mode == "p21" || mode == "both" {
		// Set PVMBG delay to exactly 3000ms as required by P2.1 specification
		setDelayBody, _ := json.Marshal(map[string]int{"min_delay_ms": 3000, "max_delay_ms": 3000})
		delayReq, _ := http.NewRequest("POST", pvmbgURL+"/admin/delay", bytes.NewReader(setDelayBody))
		delayReq.Header.Set("Authorization", "Bearer "+pvmbgToken)
		delayReq.Header.Set("Content-Type", "application/json")
		if dResp, err := httpClient.Do(delayReq); err == nil {
			io.Copy(io.Discard, dResp.Body)
			dResp.Body.Close()
		}

		var bgWg sync.WaitGroup
		// Background requests: direct PVMBG calls & gateway volcanic calls taking ~3s
		for i := 0; i < 10; i++ {
			bgWg.Add(1)
			go func(idx int) {
				defer bgWg.Done()
				if idx%2 == 0 {
					req, _ := http.NewRequest("GET", pvmbgURL+"/volcanic-reports", nil)
					req.Header.Set("Authorization", "Bearer "+pvmbgToken)
					if r, err := httpClient.Do(req); err == nil {
						io.Copy(io.Discard, r.Body)
						r.Body.Close()
					}
				} else {
					req, _ := http.NewRequest("GET", apiURL+"/hazards?type=VOLCANIC&limit=15", nil)
					req.Header.Set("Authorization", "Bearer "+tokenVal.Load().(string))
					if r, err := httpClient.Do(req); err == nil {
						io.Copy(io.Discard, r.Body)
						r.Body.Close()
					}
				}
			}(i)
		}

		// Warm up HTTP connection pool
		for w := 0; w < 3; w++ {
			if wReq, err := http.NewRequest("GET", apiURL+"/hazards?type=SEISMIC&limit=1", nil); err == nil {
				wReq.Header.Set("Authorization", "Bearer "+tokenVal.Load().(string))
				if wResp, err := httpClient.Do(wReq); err == nil {
					io.Copy(io.Discard, wResp.Body)
					wResp.Body.Close()
				}
			}
		}

		var p21Mu sync.Mutex
		var p21Latencies []float64
		var p21Wg sync.WaitGroup
		for i := 0; i < 50; i++ {
			p21Wg.Add(1)
			go func(id int) {
				defer p21Wg.Done()
				t0 := time.Now()
				req, _ := http.NewRequest("GET", apiURL+"/hazards?type=SEISMIC&limit=15", nil)
				req.Header.Set("Authorization", "Bearer "+tokenVal.Load().(string))
				req.Header.Set("X-Correlation-ID", fmt.Sprintf("p21-bmkg-only-%d", id))
				resp, err := httpClient.Do(req)
				dur := float64(time.Since(t0).Microseconds()) / 1000.0
				if err == nil {
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					if resp.StatusCode == 200 {
						p21Mu.Lock()
						p21Latencies = append(p21Latencies, dur)
						p21Mu.Unlock()
					}
				}
			}(i)
		}
		p21Wg.Wait()
		bgWg.Wait()

		// Reset PVMBG delay to standard 500-3000ms
		resetDelayBody, _ := json.Marshal(map[string]int{"min_delay_ms": 500, "max_delay_ms": 3000})
		resetReq, _ := http.NewRequest("POST", pvmbgURL+"/admin/delay", bytes.NewReader(resetDelayBody))
		resetReq.Header.Set("Authorization", "Bearer "+pvmbgToken)
		resetReq.Header.Set("Content-Type", "application/json")
		if rResp, err := httpClient.Do(resetReq); err == nil {
			io.Copy(io.Discard, rResp.Body)
			rResp.Body.Close()
		}

		sort.Float64s(p21Latencies)
		p21P50 := round2(percentile(p21Latencies, 50))
		p21P95 := round2(percentile(p21Latencies, 95))
		p21P99 := round2(percentile(p21Latencies, 99))

		if mode == "p21" {
			close(stopRefresh)
			out := map[string]any{
				"test":                       "P2.1_bmkg_only_isolation",
				"pvmbg_simulated_delay_sec":  3,
				"concurrent_seismic_requests": len(p21Latencies),
				"concurrent_pvmbg_requests":   10,
				"latency_ms": map[string]float64{
					"min": round2(percentile(p21Latencies, 0)),
					"avg": round2(avg(p21Latencies)),
					"p50": p21P50,
					"p95": p21P95,
					"p99": p21P99,
					"max": round2(percentile(p21Latencies, 100)),
				},
			}
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			_ = enc.Encode(out)
			if p21P95 < 300.0 && len(p21Latencies) > 0 {
				os.Exit(0)
			}
			os.Exit(1)
		}
	}

	startTime := time.Now()
	deadline := startTime.Add(time.Duration(durSec) * time.Second)

	var (
		mu       sync.Mutex
		samples  []sample
		totalReq atomic.Int64
		cnt200   atomic.Int64
		cnt429   atomic.Int64
		cntErr   atomic.Int64
	)

	var wg sync.WaitGroup
	for v := 0; v < vus; v++ {
		wg.Add(1)
		go func(vuID int) {
			defer wg.Done()
			localSamples := make([]sample, 0, 1024)
			iter := 0
			for time.Now().Before(deadline) {
				iter++
				bmkgOnly := (iter % 2) == 0
				target := apiURL + "/hazards?type=SEISMIC&limit=20"
				if !bmkgOnly {
					if iter%4 == 1 {
						target = apiURL + "/hazards?type=VOLCANIC&limit=20"
					} else {
						target = apiURL + "/hazards?limit=20"
					}
				}

				req, _ := http.NewRequest("GET", target, nil)
				req.Header.Set("Authorization", "Bearer "+tokenVal.Load().(string))
				req.Header.Set("X-Correlation-ID", fmt.Sprintf("loadtest-vu%d-it%d", vuID, iter))

				t0 := time.Now()
				resp, err := httpClient.Do(req)
				durMs := float64(time.Since(t0).Microseconds()) / 1000.0

				status := 0
				if err == nil {
					status = resp.StatusCode
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}

				totalReq.Add(1)
				if status == 200 {
					cnt200.Add(1)
				} else if status == 429 {
					cnt429.Add(1)
				} else {
					cntErr.Add(1)
				}

				localSamples = append(localSamples, sample{
					durationMs: durMs,
					statusCode: status,
					bmkgOnly:   bmkgOnly,
				})

				time.Sleep(25 * time.Millisecond)
			}

			mu.Lock()
			samples = append(samples, localSamples...)
			mu.Unlock()
		}(v)
	}

	wg.Wait()
	close(stopRefresh)

	actualDuration := time.Since(startTime).Seconds()
	allDurs := make([]float64, 0, len(samples))
	bmkgDurs := make([]float64, 0, len(samples)/2)

	for _, s := range samples {
		allDurs = append(allDurs, s.durationMs)
		if s.bmkgOnly && s.statusCode == 200 {
			bmkgDurs = append(bmkgDurs, s.durationMs)
		}
	}

	sort.Float64s(allDurs)
	sort.Float64s(bmkgDurs)

	total := totalReq.Load()
	ok200 := cnt200.Load()
	rej429 := cnt429.Load()
	uncontrolled := cntErr.Load()
	throughput := float64(total) / actualDuration
	errRatePct := 0.0
	if total > 0 {
		errRatePct = (float64(uncontrolled) / float64(total)) * 100.0
	}

	bmkgP95 := round2(percentile(bmkgDurs, 95))
	out := map[string]any{
		"test":                       "P2.2_sustained_load_test",
		"parallel_connections_vus":   vus,
		"duration_seconds":           round2(actualDuration),
		"total_requests":             total,
		"throughput_req_per_sec":     round2(throughput),
		"http_200_ok":                ok200,
		"http_429_controlled_reject": rej429,
		"uncontrolled_errors":        uncontrolled,
		"uncontrolled_error_rate_pct": round4(errRatePct),
		"latency_ms": map[string]float64{
			"min":           round2(percentile(allDurs, 0)),
			"avg":           round2(avg(allDurs)),
			"p50":           round2(percentile(allDurs, 50)),
			"p95":           round2(percentile(allDurs, 95)),
			"p99":           round2(percentile(allDurs, 99)),
			"max":           round2(percentile(allDurs, 100)),
			"bmkg_only_p95": bmkgP95,
		},
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(out)

	os.Exit(0)
}
EOF

CLIENT_API_URL="$CLIENT_API_URL" \
AUTH_URL="$AUTH_URL" \
PVMBG_URL="$PVMBG_URL" \
PVMBG_TOKEN="$PVMBG_TOKEN" \
CLIENT_ID="$CLIENT_OPS_ID" \
CLIENT_SECRET="$CLIENT_OPS_SECRET" \
VUS="$VUS" \
DURATION_SEC="$DURATION_SEC" \
MODE="$MODE" \
go run "${TMP_GO_DIR}/main.go"
