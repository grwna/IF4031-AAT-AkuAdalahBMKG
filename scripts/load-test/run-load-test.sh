#!/usr/bin/env bash

# ==============================================================================
# Load Testing & Concurrency Benchmark Runner - Problem 2 (IF4031 Milestone 1)
# Mencakup:
#   - P2.1: Isolasi Read-Path (p95 latensi BMKG-only < 300 ms saat PVMBG delay 3s)
#   - P2.2: Sustained Load Testing (>= 50 koneksi paralel selama >= 60 detik,
#           melaporkan Throughput, p50/p95/p99, HTTP 200, HTTP 429, dan
#           Uncontrolled Error Rate < 1%)
# Mendukung eksekusi via:
#   1. k6 lokal (jika tersedia)
#   2. Built-in Go Concurrent Load Generator (zero external binary dependency)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
CLIENT_OPS_SECRET="${CLIENT_OPS_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_SECRET" "your-bnpb-ops-secret-here")}"
PVMBG_TOKEN="${PVMBG_TOKEN:-$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PVMBG_BEARER_TOKEN" "pvmbg-secret-token-456")}"

VUS="${VUS:-55}"
DURATION_SEC="${DURATION_SEC:-60}"
ENGINE="${ENGINE:-auto}" # auto | k6 | go
REPORT_DIR="${PROJECT_ROOT}/scripts/load-test/reports"
SAVE_REPORT="true"

usage() {
    cat <<EOF
Penggunaan: $(basename "$0") [PILIHAN]

Runner Load Testing & Benchmark Concurrency Problem 2 (P2.1 & P2.2).

Pilihan:
  -c, --vus <jumlah>       Jumlah koneksi paralel / Virtual Users (default: 55, syarat >= 50)
  -d, --duration <detik>   Durasi sustained load test dalam detik (default: 60, syarat >= 60)
  -e, --engine <mode>      Engine load test: auto | k6 | go (default: auto)
  --quick                  Mode uji cepat (55 koneksi paralel selama 10 detik)
  --no-save                Jangan simpan laporan ke file
  -h, --help               Tampilkan bantuan ini

Contoh:
  ./scripts/load-test/run-load-test.sh                 # Full 60 detik dengan >= 50 koneksi paralel
  ./scripts/load-test/run-load-test.sh --quick         # Uji cepat 10 detik
  ./scripts/load-test/run-load-test.sh --engine k6     # Paksa gunakan k6
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
            echo -e "${RED}Argumen tidak dikenal: $1${NC}"
            usage
            ;;
    esac
done

if [[ "$SAVE_REPORT" == "true" ]]; then
    mkdir -p "$REPORT_DIR"
    TS=$(date +"%Y%m%d-%H%M%S")
    REPORT_FILE="${REPORT_DIR}/load-test-${VUS}vus-${DURATION_SEC}s-${TS}.log"
    exec > >(tee >(sed $'s/\033\[[0-9;]*m//g' > "$REPORT_FILE")) 2>&1
fi

echo -e "${CYAN}${BOLD}"
echo "================================================================================"
echo "   IF4031 PROBLEM 2 — CONCURRENCY & SUSTAINED LOAD TESTING SUITE                "
echo "================================================================================"
echo -e "${NC}"
echo -e "Client-Facing API : ${YELLOW}${CLIENT_API_URL}${NC}"
echo -e "Auth Service      : ${YELLOW}${AUTH_URL}${NC}"
echo -e "Parallel VUs      : ${MAGENTA}${BOLD}${VUS} koneksi paralel${NC} (Syarat M1: >= 50)"
echo -e "Sustained Duration: ${MAGENTA}${BOLD}${DURATION_SEC} detik${NC} (Syarat M1: >= 60 detik)"
if [[ "$SAVE_REPORT" == "true" ]]; then
    echo -e "Report File       : ${GREEN}${REPORT_FILE}${NC}"
fi
echo ""

# Pastikan PVMBG tidak dalam kondisi outage sebelum load test
curl -s -X POST "${PVMBG_URL}/admin/outage" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${PVMBG_TOKEN}" \
     -d '{"outage": false}' > /dev/null 2>&1 || true

# Verifikasi kesiapan Auth Service & Client-API
if ! curl -s -f "${CLIENT_API_URL}/health" > /dev/null; then
    echo -e "${RED}Error: Client-Facing API (${CLIENT_API_URL}/health) tidak dapat dijangkau! Pastikan docker compose up sudah berjalan.${NC}"
    exit 1
fi

# Pilih engine
SELECTED_ENGINE="$ENGINE"
if [[ "$SELECTED_ENGINE" == "auto" ]]; then
    if command -v k6 &> /dev/null; then
        SELECTED_ENGINE="k6"
    else
        SELECTED_ENGINE="go"
    fi
fi

echo -e "${BLUE}${BOLD}▶ Menggunakan Load Test Engine: ${SELECTED_ENGINE}${NC}\n"

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

# Built-in Go High-Concurrency Sustained Load Tester (mendukung auto-refresh token,
# kalkulasi presisi p50/p95/p99, pemisahan metrik BMKG-only vs Mixed, dan HTTP 429)
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

func main() {
	apiURL := os.Getenv("CLIENT_API_URL")
	authURL := os.Getenv("AUTH_URL")
	pvmbgURL := os.Getenv("PVMBG_URL")
	pvmbgToken := os.Getenv("PVMBG_TOKEN")
	clientID := os.Getenv("CLIENT_ID")
	clientSecret := os.Getenv("CLIENT_SECRET")
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
		fmt.Printf("Gagal mengambil token awal: %v\n", err)
		os.Exit(1)
	}
	tokenVal.Store(initialTok)

	// Background goroutine untuk auto-refresh token setiap 30 detik (karena TTL default 60 detik)
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

	// =========================================================================
	// TAHAP 1: P2.1 — Benchmark Isolasi BMKG-only vs PVMBG 3s Delay
	// =========================================================================
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println("  TAHAP 1 (Kriteria P2.1): Uji Isolasi BMKG-only Saat PVMBG Delay Tinggi")
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	// Kirim 10 request lambat ke PVMBG & VOLCANIC secara bersamaan dengan 50 request BMKG-only
	var bgWg sync.WaitGroup
	for i := 0; i < 10; i++ {
		bgWg.Add(1)
		go func() {
			defer bgWg.Done()
			req, _ := http.NewRequest("GET", pvmbgURL+"/volcanic-reports", nil)
			req.Header.Set("Authorization", "Bearer "+pvmbgToken)
			if r, err := httpClient.Do(req); err == nil {
				io.Copy(io.Discard, r.Body)
				r.Body.Close()
			}
		}()
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

	sort.Float64s(p21Latencies)
	p21P50 := percentile(p21Latencies, 50)
	p21P95 := percentile(p21Latencies, 95)
	p21P99 := percentile(p21Latencies, 99)
	fmt.Printf("  Sampel BMKG-only (SEISMIC) : %d request paralel bersamaan dengan trafik PVMBG\n", len(p21Latencies))
	fmt.Printf("  Latensi BMKG-only          : avg=%.2fms | p50=%.2fms | p95=%.2fms | p99=%.2fms\n",
		avg(p21Latencies), p21P50, p21P95, p21P99)
	if p21P95 < 300.0 && len(p21Latencies) > 0 {
		fmt.Printf("  Status Kriteria P2.1       : PASS (p95 %.2fms < 300ms)\n\n", p21P95)
	} else {
		fmt.Printf("  Status Kriteria P2.1       : FAIL (p95 %.2fms >= 300ms)\n\n", p21P95)
	}

	// =========================================================================
	// TAHAP 2: P2.2 — Sustained Load Testing (>= 50 Koneksi Paralel, >= 60 Detik)
	// =========================================================================
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("  TAHAP 2 (Kriteria P2.2): Sustained Load Test (%d Koneksi Paralel, %d Detik)\n", vus, durSec)
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

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

	// Progress reporter setiap 10 detik
	doneProg := make(chan struct{})
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-doneProg:
				return
			case <-ticker.C:
				elapsed := int(time.Since(startTime).Seconds())
				fmt.Printf("  [Progress %2ds/%2ds] Total=%d | 200 OK=%d | 429 Controlled=%d | Uncontrolled Err=%d\n",
					elapsed, durSec, totalReq.Load(), cnt200.Load(), cnt429.Load(), cntErr.Load())
			}
		}
	}()

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

				// Pacing 25ms per VU agar menghasilkan sustained load realistis (~1500-2200 req/s pada 55 VU)
				time.Sleep(25 * time.Millisecond)
			}

			mu.Lock()
			samples = append(samples, localSamples...)
			mu.Unlock()
		}(v)
	}

	wg.Wait()
	close(doneProg)
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

	fmt.Println("\n================================================================================")
	fmt.Println("                HASIL PENGUKURAN LOAD TESTING (PROBLEM 2)                       ")
	fmt.Println("================================================================================")
	fmt.Printf("  Konfigurasi Beban          : %d Koneksi Paralel (VUs) selama %.2f detik\n", vus, actualDuration)
	fmt.Printf("  Total Request Terkirim     : %d requests\n", total)
	fmt.Printf("  Throughput Rata-rata       : %.2f req/detik\n", throughput)
	fmt.Println("--------------------------------------------------------------------------------")
	fmt.Printf("  Distribusi Latensi (Semua) : min=%.2fms | avg=%.2fms | p50=%.2fms | p95=%.2fms | p99=%.2fms | max=%.2fms\n",
		percentile(allDurs, 0), avg(allDurs), percentile(allDurs, 50), percentile(allDurs, 95), percentile(allDurs, 99), percentile(allDurs, 100))
	fmt.Printf("  Distribusi BMKG-only (200) : min=%.2fms | avg=%.2fms | p50=%.2fms | p95=%.2fms | p99=%.2fms | max=%.2fms\n",
		percentile(bmkgDurs, 0), avg(bmkgDurs), percentile(bmkgDurs, 50), percentile(bmkgDurs, 95), percentile(bmkgDurs, 99), percentile(bmkgDurs, 100))
	fmt.Println("--------------------------------------------------------------------------------")
	fmt.Printf("  HTTP 200 OK                : %d (%.2f%%)\n", ok200, (float64(ok200)/float64(total))*100.0)
	fmt.Printf("  HTTP 429 (Controlled Rej.) : %d (%.2f%%) [Dilaporkan & bukan kegagalan]\n", rej429, (float64(rej429)/float64(total))*100.0)
	fmt.Printf("  Uncontrolled Error (5xx/0) : %d (%.4f%%) [Batas Maksimum: < 1.00%%]\n", uncontrolled, errRatePct)
	fmt.Println("================================================================================")

	bmkgP95 := percentile(bmkgDurs, 95)
	if errRatePct < 1.0 && bmkgP95 < 300.0 {
		fmt.Printf("\n✓ KESIMPULAN P2.1 & P2.2: LULUS (BMKG-only p95=%.2fms < 300ms, Uncontrolled Error Rate=%.4f%% < 1%%)\n\n", bmkgP95, errRatePct)
		os.Exit(0)
	} else {
		fmt.Printf("\n✗ KESIMPULAN P2.1 & P2.2: GAGAL (BMKG-only p95=%.2fms, Uncontrolled Error Rate=%.4f%%)\n\n", bmkgP95, errRatePct)
		os.Exit(1)
	}
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
go run "${TMP_GO_DIR}/main.go"
