#!/usr/bin/env bash

# ==============================================================================
# Full End-to-End (E2E) Test Suite - IF4031 Milestone 1 (AkuAdalahBMKG)
# Mencakup: Ketentuan Implementasi (1-7) & Problem Set (P1 - P5)
# Spesifikasi: ctx-IF4031 - Tugas Besar - M1.md
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Konfigurasi Warna Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Helper untuk membaca nilai variabel dari file .env tanpa mengeksekusi shell
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

# Muat konfigurasi otomatis dari berkas .env masing-masing service (dengan fallback aman)
BMKG_PORT=$(read_env_var "${PROJECT_ROOT}/services/bmkg-mock/.env" "PORT" "8081")
PVMBG_PORT=$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PORT" "8082")
AGGREGATOR_PORT=$(read_env_var "${PROJECT_ROOT}/services/aggregator/.env" "PORT" "8083")
CLIENT_API_PORT=$(read_env_var "${PROJECT_ROOT}/services/client-api/.env" "PORT" "8080")
AUTH_PORT=$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "PORT" "8084")

BMKG_URL="${BMKG_URL:-http://localhost:${BMKG_PORT}}"
PVMBG_URL="${PVMBG_URL:-http://localhost:${PVMBG_PORT}}"
AGGREGATOR_URL="${AGGREGATOR_URL:-http://localhost:${AGGREGATOR_PORT}}"
CLIENT_API_URL="${CLIENT_API_URL:-http://localhost:${CLIENT_API_PORT}}"
AUTH_URL="${AUTH_URL:-http://localhost:${AUTH_PORT}}"
RABBITMQ_MGMT_URL="${RABBITMQ_MGMT_URL:-http://localhost:15672}"

BMKG_API_KEY="${BMKG_API_KEY:-$(read_env_var "${PROJECT_ROOT}/services/bmkg-mock/.env" "BMKG_API_KEY" "bmkg-secret-key-123")}"
PVMBG_TOKEN="${PVMBG_TOKEN:-$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PVMBG_BEARER_TOKEN" "pvmbg-secret-token-456")}"

CLIENT_MEDIA_ID="${CLIENT_MEDIA_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_ID" "media-client")}"
CLIENT_MEDIA_SECRET="${CLIENT_MEDIA_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_SECRET" "your-media-client-secret-here")}"

CLIENT_FIELD_ID="${CLIENT_FIELD_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_ID" "field-team")}"
CLIENT_FIELD_SECRET="${CLIENT_FIELD_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_SECRET" "your-field-team-secret-here")}"

CLIENT_OPS_ID="${CLIENT_OPS_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_ID" "bnpb-ops")}"
CLIENT_OPS_SECRET="${CLIENT_OPS_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_SECRET" "your-bnpb-ops-secret-here")}"

ACCESS_TOKEN_TTL=$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "ACCESS_TOKEN_TTL_SECONDS" "60")

RABBITMQ_USER="${RABBITMQ_USER:-$(read_env_var "${PROJECT_ROOT}/services/message-broker/.env" "RABBITMQ_DEFAULT_USER" "bnpb")}"
RABBITMQ_PASS="${RABBITMQ_PASS:-$(read_env_var "${PROJECT_ROOT}/services/message-broker/.env" "RABBITMQ_DEFAULT_PASS" "bnpbpass123")}"

POSTGRES_USER=$(read_env_var "${PROJECT_ROOT}/.env" "POSTGRES_USER" "aggregator_user")
POSTGRES_DB=$(read_env_var "${PROJECT_ROOT}/.env" "POSTGRES_DB" "canonical_store")

# Flags Mode Eksekusi
SHOW_DETAILS="${SHOW_DETAILS:-true}"
FAST_MODE="false"
NO_DOCKER="false"
TARGET_PROBLEM="all"
SAVE_REPORT="true"
REPORT_DIR="${PROJECT_ROOT}/scripts/tests/reports"

# Statistik Pengujian
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
TOTAL_TESTS=0
FAILED_LIST=()

usage() {
    cat <<EOF
Penggunaan: $(basename "$0") [PILIHAN]

Suite Pengujian End-to-End (E2E) Menyeluruh untuk BNPB Distributed Platform (Milestone 1).
Secara default menjalankan seluruh test case (Ketentuan 1-7 & Problem 1-5), termasuk
uji kedaluwarsa alami TTL token (60 detik) dan manipulasi container Docker.

Pilihan:
  --fast                 Lewati tunggu 60 detik TTL token alami (mode cepat ~35 detik)
  --no-docker            Lewati test yang memanipulasi container Docker (stop/start/exec)
  --problem <nama>       Jalankan kategori tertentu saja: all | ketentuan | p1 | p2 | p3 | p4 | p5
  --compact              Sembunyikan rincian Request/Response/Expected (mode ringkas)
  --no-save              Jangan simpan berkas laporan log otomatis
  --report-dir <dir>     Direktori penyimpanan bukti log (default: scripts/tests/reports)
  -h, --help             Tampilkan bantuan ini

Contoh:
  ./scripts/tests/test-e2e.sh
  ./scripts/tests/test-e2e.sh --fast
  ./scripts/tests/test-e2e.sh --problem p3
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast)
            FAST_MODE="true"
            shift
            ;;
        --no-docker)
            NO_DOCKER="true"
            shift
            ;;
        --problem)
            TARGET_PROBLEM=$(echo "$2" | tr '[:upper:]' '[:lower:]')
            shift 2
            ;;
        --compact)
            SHOW_DETAILS="false"
            shift
            ;;
        --no-save)
            SAVE_REPORT="false"
            shift
            ;;
        --report-dir)
            REPORT_DIR="$2"
            shift 2
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

# Setup pencatatan bukti log otomatis untuk laporan PDF
if [[ "$SAVE_REPORT" == "true" ]]; then
    mkdir -p "$REPORT_DIR"
    TIMESTAMP_STR=$(date +"%Y%m%d-%H%M%S")
    REPORT_FILE="${REPORT_DIR}/e2e-report-${TARGET_PROBLEM}-${TIMESTAMP_STR}.log"
    EVIDENCE_FILE="${REPORT_DIR}/e2e-evidence-logs-${TIMESTAMP_STR}.log"
    exec > >(tee >(sed $'s/\033\[[0-9;]*m//g' > "$REPORT_FILE")) 2>&1
fi

check_dependencies() {
    for cmd in curl jq python3; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}Error: Perintah '$cmd' tidak ditemukan. Harap install '$cmd' terlebih dahulu.${NC}"
            exit 1
        fi
    done
    if [[ "$NO_DOCKER" == "false" ]]; then
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}Peringatan: 'docker' tidak ditemukan, mengaktifkan --no-docker secara otomatis.${NC}"
            NO_DOCKER="true"
        fi
    fi
}

now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

# Cleanup trap agar kondisi mock dan container selalu kembali bersih
cleanup() {
    echo ""
    echo -e "${YELLOW}▶ Menjalankan cleanup handler (mengembalikan state normal sistem)...${NC}"
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": false}' > /dev/null 2>&1 || true

    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"enabled": false}' > /dev/null 2>&1 || true

    if [[ "$NO_DOCKER" == "false" ]]; then
        (cd "$PROJECT_ROOT" && docker compose start auth-service aggregator consumer-notifier consumer-dashboard > /dev/null 2>&1 || true)
        (cd "$PROJECT_ROOT" && docker compose --profile p5-extra stop consumer-pemda-volcano > /dev/null 2>&1 || true)
        (cd "$PROJECT_ROOT" && docker compose --profile p5-extra rm -f consumer-pemda-volcano > /dev/null 2>&1 || true)
    fi
    echo -e "${GREEN}✓ Cleanup selesai.${NC}"
}
trap cleanup EXIT

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================================"
    echo "   IF4031 MILESTONE 1 - COMPREHENSIVE E2E TEST SUITE (AKU ADALAH BMKG)          "
    echo "================================================================================"
    echo -e "${NC}"
    echo -e "Project Root   : ${YELLOW}${PROJECT_ROOT}${NC}"
    echo -e "BMKG Mock      : ${YELLOW}${BMKG_URL}${NC}"
    echo -e "PVMBG Mock     : ${YELLOW}${PVMBG_URL}${NC}"
    echo -e "Aggregator     : ${YELLOW}${AGGREGATOR_URL}${NC}"
    echo -e "Client-API     : ${YELLOW}${CLIENT_API_URL}${NC}"
    echo -e "Auth-Service   : ${YELLOW}${AUTH_URL}${NC}"
    echo -e "RabbitMQ Mgmt  : ${YELLOW}${RABBITMQ_MGMT_URL}${NC}"
    echo -e "Target Scope   : ${MAGENTA}${BOLD}${TARGET_PROBLEM}${NC} (Fast=${FAST_MODE}, NoDocker=${NO_DOCKER})"
    if [[ "$SAVE_REPORT" == "true" ]]; then
        echo -e "Report File    : ${GREEN}${REPORT_FILE}${NC}"
    fi
    echo ""
}

print_section() {
    local title="$1"
    echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}  ${title}${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

assert_start() {
    local code="$1"
    local test_name="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    CURRENT_TEST_LABEL="[${code}] ${test_name}"
    echo -e "${BLUE}[TEST ${TOTAL_TESTS} | ${code}]${NC} ${BOLD}${test_name}${NC}"
}

print_interaction_details() {
    local method="$1"
    local url="$2"
    local headers="$3"
    local req_body="$4"
    local resp_code="$5"
    local resp_body="$6"
    local expected_desc="$7"

    if [[ "$SHOW_DETAILS" == "true" ]]; then
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ OUTGOING REQUEST / ACTION                                                │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${BOLD}Action / URL :${NC} ${BOLD}${method}${NC} ${url}"
        if [[ -n "$headers" ]]; then
            echo -e "    ${YELLOW}Headers/Info :${NC} ${headers}"
        fi
        if [[ -n "$req_body" ]] && [[ "$req_body" != "null" ]]; then
            echo -e "    ${YELLOW}Payload      :${NC} $(echo "$req_body" | jq -c . 2>/dev/null || echo "$req_body")"
        fi
        echo ""
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ RECEIVED RESPONSE / OBSERVED STATE                                       │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${YELLOW}Status       :${NC} ${resp_code}"
        if [[ -n "$resp_body" ]]; then
            echo -e "    ${YELLOW}Output / Body:${NC}"
            echo -e "$resp_body" | sed 's/^/      /'
        fi
        echo ""
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ EXPECTED ASSERTION                                                       │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${BOLD}${expected_desc}${NC}"
        echo -e "  ${CYAN}└──────────────────────────────────────────────────────────────────────────┘${NC}"
    fi
}

assert_pass() {
    local message="$1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✓ PASS:${NC} ${message}\n"
}

assert_fail() {
    local message="$1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_LIST+=("${CURRENT_TEST_LABEL}: ${message}")
    echo -e "  ${RED}✗ FAIL:${NC} ${message}\n"
}

assert_skip() {
    local message="$1"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    echo -e "  ${YELLOW}↷ SKIP:${NC} ${message}\n"
}

should_run() {
    local section="$1"
    [[ "$TARGET_PROBLEM" == "all" || "$TARGET_PROBLEM" == "$section" ]]
}

# Pastikan state awal PVMBG & DB bersih sebelum test dimulai
reset_pvmbg_state() {
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": false}' > /dev/null 2>&1 || true
    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"enabled": false}' > /dev/null 2>&1 || true
    if [[ "$NO_DOCKER" == "false" ]]; then
        (cd "$PROJECT_ROOT" && docker compose exec -T canonical-store psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DELETE FROM hazard_events WHERE latitude IS NULL;" > /dev/null 2>&1) || true
    fi
}

# ==============================================================================
# MULAI EKSEKUSI
# ==============================================================================
check_dependencies
print_banner
reset_pvmbg_state

# Variabel global token untuk dipakai lintas test
MEDIA_ACCESS_TOKEN=""
FIELD_ACCESS_TOKEN=""
FIELD_REFRESH_TOKEN=""
OPS_ACCESS_TOKEN=""
SAMPLE_HAZARD_ID=""

# ==============================================================================
# BAGIAN 0: KETENTUAN IMPLEMENTASI (POIN 1 - 7) & MODEL INGEST
# ==============================================================================
if should_run "ketentuan"; then
    print_section "BAGIAN 0: KETENTUAN IMPLEMENTASI (POIN 1-7) & MODEL INGEST"

    # --------------------------------------------------------------------------
    # TEST K1: Health Check Seluruh Service & Container
    # --------------------------------------------------------------------------
    assert_start "KETENTUAN-7" "Health Check Seluruh Service HTTP & Internal Consumer"

    BMKG_H=$(curl -s -w "\n%{http_code}" "${BMKG_URL}/health" || echo -e "\n000")
    BMKG_H_CODE=$(echo "$BMKG_H" | tail -n 1)

    PVMBG_H=$(curl -s -w "\n%{http_code}" "${PVMBG_URL}/health" || echo -e "\n000")
    PVMBG_H_CODE=$(echo "$PVMBG_H" | tail -n 1)

    AGG_H=$(curl -s -w "\n%{http_code}" "${AGGREGATOR_URL}/health" || echo -e "\n000")
    AGG_H_CODE=$(echo "$AGG_H" | tail -n 1)

    API_H=$(curl -s -w "\n%{http_code}" "${CLIENT_API_URL}/health" || echo -e "\n000")
    API_H_CODE=$(echo "$API_H" | tail -n 1)
    API_H_BODY=$(echo "$API_H" | sed '$d')

    AUTH_H=$(curl -s -w "\n%{http_code}" "${AUTH_URL}/health" || echo -e "\n000")
    AUTH_H_CODE=$(echo "$AUTH_H" | tail -n 1)
    AUTH_H_BODY=$(echo "$AUTH_H" | sed '$d')

    DASH_H_CODE="SKIPPED"
    NOTIF_H_CODE="SKIPPED"
    if [[ "$NO_DOCKER" == "false" ]]; then
        DASH_H_BODY=$(cd "$PROJECT_ROOT" && docker compose exec -T consumer-dashboard wget -qO- http://localhost:8085/health 2>/dev/null || echo "")
        [[ -n "$DASH_H_BODY" ]] && DASH_H_CODE="200" || DASH_H_CODE="503"
        NOTIF_H_BODY=$(cd "$PROJECT_ROOT" && docker compose exec -T consumer-notifier wget -qO- http://localhost:8086/health 2>/dev/null || echo "")
        [[ -n "$NOTIF_H_BODY" ]] && NOTIF_H_CODE="200" || NOTIF_H_CODE="503"
    fi

    print_interaction_details \
        "GET" "/health (BMKG:8081, PVMBG:8082, Aggregator:8083, Client-API:8080, Auth:8084, Consumers:8085/8086)" \
        "No Auth Required" "" \
        "BMKG=${BMKG_H_CODE}, PVMBG=${PVMBG_H_CODE}, AGG=${AGG_H_CODE}, API=${API_H_CODE}, AUTH=${AUTH_H_CODE}, DASH=${DASH_H_CODE}, NOTIF=${NOTIF_H_CODE}" \
        "Client-API Health: ${API_H_BODY}\nAuth Health: ${AUTH_H_BODY}" \
        "Seluruh service wajib menyediakan endpoint /health yang mengembalikan HTTP 200 (status UP)."

    if [[ "$BMKG_H_CODE" == "200" && "$PVMBG_H_CODE" == "200" && "$AGG_H_CODE" == "200" && "$API_H_CODE" == "200" && "$AUTH_H_CODE" == "200" ]] && \
       [[ "$DASH_H_CODE" == "200" || "$DASH_H_CODE" == "SKIPPED" ]] && [[ "$NOTIF_H_CODE" == "200" || "$NOTIF_H_CODE" == "SKIPPED" ]]; then
        assert_pass "Seluruh 7 service (BMKG, PVMBG, Aggregator, Client-API, Auth, Consumer Dashboard, Consumer Notifier) sehat (200 UP)."
    else
        assert_fail "Satu atau lebih service gagal health check: BMKG=${BMKG_H_CODE}, PVMBG=${PVMBG_H_CODE}, AGG=${AGG_H_CODE}, API=${API_H_CODE}, AUTH=${AUTH_H_CODE}, DASH=${DASH_H_CODE}, NOTIF=${NOTIF_H_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST K2: Seed Minimal 20 Record Historis pada BMKG & PVMBG
    # --------------------------------------------------------------------------
    assert_start "MODEL-INGEST" "Seed Minimal 20 Record Historis pada BMKG & PVMBG serta Endpoint TsunamiWarning"

    BMKG_SEED_RESP=$(curl -s -w "\n%{http_code}" -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events" || echo -e "\n000")
    BMKG_SEED_CODE=$(echo "$BMKG_SEED_RESP" | tail -n 1)
    BMKG_SEED_BODY=$(echo "$BMKG_SEED_RESP" | sed '$d')
    BMKG_COUNT=$(echo "$BMKG_SEED_BODY" | jq 'length' 2>/dev/null || echo "0")

    TSUNAMI_RESP=$(curl -s -w "\n%{http_code}" -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/tsunami-warnings" || echo -e "\n000")
    TSUNAMI_CODE=$(echo "$TSUNAMI_RESP" | tail -n 1)
    TSUNAMI_BODY=$(echo "$TSUNAMI_RESP" | sed '$d')
    TSUNAMI_COUNT=$(echo "$TSUNAMI_BODY" | jq 'length' 2>/dev/null || echo "0")

    PVMBG_SEED_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" || echo -e "\n000")
    PVMBG_SEED_CODE=$(echo "$PVMBG_SEED_RESP" | tail -n 1)
    PVMBG_SEED_BODY=$(echo "$PVMBG_SEED_RESP" | sed '$d')
    PVMBG_COUNT=$(echo "$PVMBG_SEED_BODY" | jq 'length' 2>/dev/null || echo "0")

    print_interaction_details \
        "GET" "${BMKG_URL}/seismic-events, /tsunami-warnings & ${PVMBG_URL}/volcanic-reports" \
        "X-BMKG-Key & Authorization: Bearer" "" \
        "BMKG=${BMKG_SEED_CODE}, Tsunami=${TSUNAMI_CODE}, PVMBG=${PVMBG_SEED_CODE}" \
        "Jumlah SeismicEvent: ${BMKG_COUNT} record (>= 20)\nJumlah TsunamiWarning: ${TSUNAMI_COUNT} record\nJumlah VolcanicReport: ${PVMBG_COUNT} record (>= 20)" \
        "Kedua mock wajib menyediakan minimal 20 record historis saat dinyalakan dan endpoint /tsunami-warnings terpisah."

    if [[ "$BMKG_SEED_CODE" == "200" && "$TSUNAMI_CODE" == "200" && "$PVMBG_SEED_CODE" == "200" ]] && \
       [[ "$BMKG_COUNT" -ge 20 && "$PVMBG_COUNT" -ge 20 && "$TSUNAMI_COUNT" -ge 1 ]]; then
        assert_pass "Seed data terverifikasi: BMKG memiliki ${BMKG_COUNT} SeismicEvent & ${TSUNAMI_COUNT} TsunamiWarning, PVMBG memiliki ${PVMBG_COUNT} VolcanicReport (>= 20 record)."
    else
        assert_fail "Seed data tidak memenuhi syarat minimal 20 record: BMKG=${BMKG_COUNT}, Tsunami=${TSUNAMI_COUNT}, PVMBG=${PVMBG_COUNT}."
    fi

    # --------------------------------------------------------------------------
    # TEST K3: Karakteristik Latensi BMKG (50-150ms) vs PVMBG (500-3000ms)
    # --------------------------------------------------------------------------
    assert_start "KONTRAK-MOCK" "Karakteristik Response Time BMKG (50-150ms) vs PVMBG (500-3000ms)"

    T_S1=$(now_ms)
    curl -s -o /dev/null -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events" || true
    T_E1=$(now_ms)
    BMKG_LAT=$((T_E1 - T_S1))

    T_S2=$(now_ms)
    curl -s -o /dev/null -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" || true
    T_E2=$(now_ms)
    PVMBG_LAT=$((T_E2 - T_S2))

    print_interaction_details \
        "GET" "${BMKG_URL}/seismic-events vs ${PVMBG_URL}/volcanic-reports" \
        "Pengukuran Latensi Langsung ke Mock" "" \
        "BMKG=${BMKG_LAT}ms, PVMBG=${PVMBG_LAT}ms" \
        "BMKG Latency : ${BMKG_LAT} ms (Target spesifikasi: delay 50-150 ms + overhead HTTP)\nPVMBG Latency: ${PVMBG_LAT} ms (Target spesifikasi: delay acak 500-3000 ms)" \
        "BMKG memiliki response time rendah & konsisten (< 400ms), sedangkan PVMBG memiliki delay infrastruktur lawas (>= 450ms)."

    if [[ "$BMKG_LAT" -ge 40 && "$BMKG_LAT" -lt 400 && "$PVMBG_LAT" -ge 450 ]]; then
        assert_pass "Karakteristik latensi sesuai kontrak: BMKG cepat (${BMKG_LAT}ms) dan PVMBG lambat/fluktuatif (${PVMBG_LAT}ms)."
    else
        assert_fail "Karakteristik latensi di luar ekspektasi: BMKG=${BMKG_LAT}ms, PVMBG=${PVMBG_LAT}ms."
    fi

    # --------------------------------------------------------------------------
    # TEST K4: Correlation ID Propagation & Structured Logging dengan Latensi
    # --------------------------------------------------------------------------
    assert_start "KETENTUAN-7" "Propagasi X-Correlation-ID Lintas Service & Pencatatan Latensi di Log Terstruktur"

    CORR_ID="e2e-trace-$(date +%s)-999"
    # Ambil token cepat untuk menembus Client-API -> Aggregator
    TMP_TOK_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}")
    TMP_TOK=$(echo "$TMP_TOK_RESP" | jq -r '.access_token // ""')

    HEADERS_OUT=$(curl -s -D - -o /dev/null \
        -H "Authorization: Bearer ${TMP_TOK}" \
        -H "X-Correlation-ID: ${CORR_ID}" \
        "${CLIENT_API_URL}/hazards?limit=2")

    RETURNED_CORR=$(echo "$HEADERS_OUT" | grep -i "^X-Correlation-ID:" | awk '{print $2}' | tr -d '\r')

    LOG_EVIDENCE="Header X-Correlation-ID returned: ${RETURNED_CORR}"
    LOG_HAS_CORR="true"
    if [[ "$NO_DOCKER" == "false" ]]; then
        sleep 1
        CLIENT_LOG_LINE=$(cd "$PROJECT_ROOT" && docker compose logs --tail=100 client-api 2>/dev/null | grep "$CORR_ID" | head -n 2 || true)
        AGG_LOG_LINE=$(cd "$PROJECT_ROOT" && docker compose logs --tail=100 aggregator 2>/dev/null | grep "correlation_id" | tail -n 2 || true)
        LOG_EVIDENCE="${LOG_EVIDENCE}\n\n[Log Client-API dengan Correlation-ID '${CORR_ID}']:\n${CLIENT_LOG_LINE}\n\n[Sample Log Aggregator]:\n${AGG_LOG_LINE}"
        if [[ "$SAVE_REPORT" == "true" ]]; then
            {
                echo "=== BUKTI LOG TERSTRUKTUR & CORRELATION ID (${CORR_ID}) ==="
                echo "$CLIENT_LOG_LINE"
                echo "$AGG_LOG_LINE"
                echo ""
            } >> "$EVIDENCE_FILE"
        fi
        if [[ -z "$CLIENT_LOG_LINE" ]]; then
            LOG_HAS_CORR="false"
        fi
    fi

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards?limit=2" \
        "X-Correlation-ID: ${CORR_ID}" "" \
        "Response Header X-Correlation-ID: ${RETURNED_CORR}" \
        "$LOG_EVIDENCE" \
        "X-Correlation-ID dikembalikan di response header dan tercatat pada JSON log terstruktur beserta duration_ms."

    if [[ "$RETURNED_CORR" == "$CORR_ID" && "$LOG_HAS_CORR" == "true" ]]; then
        assert_pass "Correlation ID (${CORR_ID}) diteruskan lintas service dan tercatat di JSON log beserta latensi panggilan keluar."
    else
        assert_fail "Propagasi Correlation ID gagal. Returned='${RETURNED_CORR}', Expected='${CORR_ID}', FoundInLog=${LOG_HAS_CORR}."
    fi
fi

# ==============================================================================
# BAGIAN 1: PROBLEM 1 — ARSITEKTUR & INTEROPERABILITAS DATA
# ==============================================================================
if should_run "p1"; then
    print_section "BAGIAN 1: PROBLEM 1 — ARSITEKTUR & INTEROPERABILITAS DATA"

    # Pastikan skema awal (confidence_level = false)
    reset_pvmbg_state
    sleep 4

    # --------------------------------------------------------------------------
    # TEST P1.1a: Pemetaan Kanonik SeismicEvent & TsunamiWarning -> HazardEvent
    # --------------------------------------------------------------------------
    assert_start "P1.1-SEISMIC" "Pemetaan Kanonik SeismicEvent (+ Korelasi TsunamiWarning) -> HazardEvent"

    SEISMIC_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: e2e-p1-seismic" "${AGGREGATOR_URL}/internal/hazards?type=SEISMIC&limit=50" || echo -e "\n000")
    SEISMIC_CODE=$(echo "$SEISMIC_RESP" | tail -n 1)
    SEISMIC_BODY=$(echo "$SEISMIC_RESP" | sed '$d')

    # Cek kelengkapan field kanonik dan aturan pemetaan severity
    SEISMIC_VALID=$(echo "$SEISMIC_BODY" | jq '
        (.data | length > 0) and
        ([.data[] | (
            (.hazard_id | startswith("BMKG-")) and
            (.source == "BMKG") and
            (.hazard_type == "SEISMIC") and
            (.severity | IN("NORMAL","WASPADA","SIAGA","AWAS")) and
            (.area_name != null and .area_name != "") and
            (.latitude != null and .longitude != null) and
            (.occurred_at != null and .ingested_at != null) and
            (.attributes.magnitude != null and .attributes.depth_km != null and .attributes.potential_tsunami != null)
        )] | all)
    ' 2>/dev/null || echo "false")

    # Cek apakah ada event berpotensi tsunami yang berkorelasi dengan tsunami_warning
    TSUNAMI_CORRELATED_SAMPLE=$(echo "$SEISMIC_BODY" | jq '.data[] | select(.attributes.tsunami_warning != null or .attributes.threat_level != null or .attributes.warning_id != null)' 2>/dev/null | head -n 25 || true)
    SAMPLE_SEISMIC=$(echo "$SEISMIC_BODY" | jq '.data[0]' 2>/dev/null || echo "{}")

    print_interaction_details \
        "GET" "${AGGREGATOR_URL}/internal/hazards?type=SEISMIC&limit=50" \
        "X-Correlation-ID: e2e-p1-seismic" "" \
        "HTTP ${SEISMIC_CODE}" \
        "Sample Kanonik SEISMIC:\n${SAMPLE_SEISMIC}" \
        "Seluruh record SEISMIC memenuhi kontrak HazardEvent (source=BMKG, severity=NORMAL/WASPADA/SIAGA/AWAS, attributes memuat magnitude, depth_km, potential_tsunami & TsunamiWarning terkait)."

    if [[ "$SEISMIC_CODE" == "200" && "$SEISMIC_VALID" == "true" ]]; then
        assert_pass "Pemetaan kanonik SeismicEvent -> HazardEvent valid pada seluruh record."
    else
        assert_fail "Pemetaan kanonik SeismicEvent gagal validasi. HTTP=${SEISMIC_CODE}, Valid=${SEISMIC_VALID}."
    fi

    # --------------------------------------------------------------------------
    # TEST P1.1b: Pemetaan Kanonik VolcanicReport (Skema Awal) -> HazardEvent
    # --------------------------------------------------------------------------
    assert_start "P1.1-VOLCANIC" "Pemetaan Kanonik VolcanicReport (Skema Awal Tanpa confidence_level) -> HazardEvent"

    VOLC_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: e2e-p1-volcanic-initial" "${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC&limit=50" || echo -e "\n000")
    VOLC_CODE=$(echo "$VOLC_RESP" | tail -n 1)
    VOLC_BODY=$(echo "$VOLC_RESP" | sed '$d')

    VOLC_VALID=$(echo "$VOLC_BODY" | jq '
        (.data | length > 0) and
        ([.data[] | (
            (.hazard_id | startswith("PVMBG-")) and
            (.source == "PVMBG") and
            (.hazard_type == "VOLCANIC") and
            (.severity | IN("NORMAL","WASPADA","SIAGA","AWAS")) and
            (.area_name != null and .area_name != "") and
            (.latitude != null and .longitude != null) and
            (.occurred_at != null and .ingested_at != null) and
            (.attributes.eruption_count_24h != null and .attributes.ash_column_height_m != null)
        )] | all)
    ' 2>/dev/null || echo "false")

    WITHOUT_CONF_COUNT=$(echo "$VOLC_BODY" | jq '[.data[] | select(.attributes.confidence_level == null)] | length' 2>/dev/null || echo "0")
    SAMPLE_VOLC_OLD=$(echo "$VOLC_BODY" | jq '[.data[] | select(.attributes.confidence_level == null)][0]' 2>/dev/null || echo "{}")

    print_interaction_details \
        "GET" "${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC&limit=50" \
        "X-Correlation-ID: e2e-p1-volcanic-initial" "" \
        "HTTP ${VOLC_CODE} (Record skema awal tanpa confidence_level: ${WITHOUT_CONF_COUNT})" \
        "Sample Kanonik VOLCANIC (Skema Lama):\n${SAMPLE_VOLC_OLD}" \
        "Pada skema awal, Aggregator memetakan volcano_id -> area_name & koordinat tabel referensi statis, serta attributes berisi eruption_count_24h & ash_column_height_m."

    if [[ "$VOLC_CODE" == "200" && "$VOLC_VALID" == "true" && "$WITHOUT_CONF_COUNT" -gt 0 ]]; then
        assert_pass "Pemetaan kanonik VolcanicReport skema awal valid (${WITHOUT_CONF_COUNT} record tanpa confidence_level)."
    else
        assert_fail "Pemetaan kanonik VolcanicReport skema awal gagal: HTTP=${VOLC_CODE}, Valid=${VOLC_VALID}, OldSchemaCount=${WITHOUT_CONF_COUNT}."
    fi

    # --------------------------------------------------------------------------
    # TEST P1.2, P1.3, P1.4: Perubahan Skema Dinamis (confidence_level) Tanpa Restart
    # --------------------------------------------------------------------------
    assert_start "P1.2-P1.4" "Evolusi Skema Aditif PVMBG (POST /admin/schema-version) Saat Runtime Tanpa Restart"

    SCHEMA_ON_RESP=$(curl -s -w "\n%{http_code}" -X POST "${PVMBG_URL}/admin/schema-version" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"enabled": true}' || echo -e "\n000")
    SCHEMA_ON_CODE=$(echo "$SCHEMA_ON_RESP" | tail -n 1)
    SCHEMA_ON_BODY=$(echo "$SCHEMA_ON_RESP" | sed '$d')

    echo -e "  ${YELLOW}ℹ Menunggu generator PVMBG (interval 10s) & polling Aggregator (maks 18 detik)...${NC}"
    WITH_CONF_COUNT=0
    VOLC_NEW_CODE="000"
    VOLC_NEW_BODY="{}"
    for ((wait_i=1; wait_i<=9; wait_i++)); do
        sleep 2
        VOLC_NEW_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: e2e-p1-volcanic-new-${wait_i}" "${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC&limit=30" || echo -e "\n000")
        VOLC_NEW_CODE=$(echo "$VOLC_NEW_RESP" | tail -n 1)
        VOLC_NEW_BODY=$(echo "$VOLC_NEW_RESP" | sed '$d')
        WITH_CONF_COUNT=$(echo "$VOLC_NEW_BODY" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
        if [[ "$WITH_CONF_COUNT" -gt 0 ]]; then
            break
        fi
    done

    SAMPLE_VOLC_NEW=$(echo "$VOLC_NEW_BODY" | jq '[.data[] | select(.attributes.confidence_level != null)][0]' 2>/dev/null || echo "{}")
    CONF_SAMPLE_VAL=$(echo "$SAMPLE_VOLC_NEW" | jq -r '.attributes.confidence_level // "null"')

    print_interaction_details \
        "POST -> GET" "${PVMBG_URL}/admin/schema-version -> ${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC" \
        "Authorization: Bearer <pvmbg-token>" '{"enabled": true}' \
        "Trigger=${SCHEMA_ON_CODE}, PollRead=${VOLC_NEW_CODE}" \
        "Trigger Response: ${SCHEMA_ON_BODY}\n\nSample Kanonik VOLCANIC (Skema Baru dengan confidence_level):\n${SAMPLE_VOLC_NEW}" \
        "Aggregator tidak crash, tidak perlu restart, dan konsisten meneruskan field baru 'confidence_level' ke dalam map 'attributes'."

    if [[ "$SCHEMA_ON_CODE" == "200" && "$VOLC_NEW_CODE" == "200" && "$WITH_CONF_COUNT" -gt 0 ]]; then
        assert_pass "Perubahan skema dinamis berhasil! ${WITH_CONF_COUNT} record memuat attributes.confidence_level (contoh: ${CONF_SAMPLE_VAL}) tanpa restart."
    else
        assert_fail "Gagal mendeteksi confidence_level di attributes setelah perubahan skema. Trigger=${SCHEMA_ON_CODE}, Count=${WITH_CONF_COUNT}."
    fi

    # Kembalikan schema-version ke false setelah memiliki record skema lama & baru di DB (untuk diuji juga di P4.2)
    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"enabled": false}' > /dev/null 2>&1 || true
fi

# ==============================================================================
# BAGIAN 2: PROBLEM 2 — CONCURRENCY, AVAILABILITY, & GRACEFUL DEGRADATION
# ==============================================================================
if should_run "p2"; then
    print_section "BAGIAN 2: PROBLEM 2 — CONCURRENCY, AVAILABILITY, & GRACEFUL DEGRADATION"

    # Ambil token BNPB Ops untuk pengujian via Client-Facing API
    P2_TOK_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}")
    P2_TOKEN=$(echo "$P2_TOK_RESP" | jq -r '.access_token // ""')

    # --------------------------------------------------------------------------
    # TEST P2.1: Anti Head-of-Line Blocking (p95 Latensi BMKG-only < 300 ms)
    # --------------------------------------------------------------------------
    assert_start "P2.1" "Anti Head-of-Line Blocking: p95 Latensi Permintaan BMKG-only (SEISMIC) < 300 ms Saat Trafik VOLCANIC Berjalan"

    # Picu request background ke PVMBG & VOLCANIC secara paralel untuk memastikan tidak terjadi head-of-line blocking
    for _ in {1..5}; do
        curl -s -o /dev/null -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" &
        curl -s -o /dev/null -H "Authorization: Bearer ${P2_TOKEN}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=20" &
    done

    LATENCY_SAMPLES=20
    LATENCIES=()
    FAILED_REQ=0

    for ((i=1; i<=LATENCY_SAMPLES; i++)); do
        T0=$(now_ms)
        CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${P2_TOKEN}" \
            -H "X-Correlation-ID: e2e-p2-hol-$i" \
            "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=10" || echo "000")
        T1=$(now_ms)
        DUR=$((T1 - T0))
        if [[ "$CODE" == "200" ]]; then
            LATENCIES+=("$DUR")
        else
            FAILED_REQ=$((FAILED_REQ + 1))
        fi
    done
    wait || true

    if [[ "${#LATENCIES[@]}" -gt 0 ]]; then
        SORTED_LAT=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
        COUNT_LAT=${#SORTED_LAT[@]}
        P50_IDX=$(( (COUNT_LAT * 50 / 100) - 1 ))
        [[ $P50_IDX -lt 0 ]] && P50_IDX=0
        P95_IDX=$(( (COUNT_LAT * 95 / 100) - 1 ))
        [[ $P95_IDX -lt 0 ]] && P95_IDX=0
        MAX_IDX=$(( COUNT_LAT - 1 ))

        MIN_LAT="${SORTED_LAT[0]}"
        P50_LAT="${SORTED_LAT[$P50_IDX]}"
        P95_LAT="${SORTED_LAT[$P95_IDX]}"
        MAX_LAT="${SORTED_LAT[$MAX_IDX]}"

        print_interaction_details \
            "GET (Concurrent)" "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=10 (x${LATENCY_SAMPLES} paralel dengan request VOLCANIC)" \
            "Authorization: Bearer <ops-token>" "" \
            "200 OK (${COUNT_LAT}/${LATENCY_SAMPLES} sukses)" \
            "Distribusi Latensi BMKG-only (SEISMIC): Min=${MIN_LAT}ms | p50=${P50_LAT}ms | p95=${P95_LAT}ms | Max=${MAX_LAT}ms" \
            "p95 latensi permintaan BMKG-only wajib tetap di bawah 300 ms meskipun PVMBG memiliki delay s/d 3 detik."

        if [[ "$P95_LAT" -lt 300 && "$FAILED_REQ" -eq 0 ]]; then
            assert_pass "Bebas Head-of-Line Blocking! p95 latensi BMKG-only = ${P95_LAT}ms (< 300ms), p50 = ${P50_LAT}ms."
        else
            assert_fail "p95 latensi BMKG-only (${P95_LAT}ms) >= 300ms atau ada request gagal (${FAILED_REQ})."
        fi
    else
        assert_fail "Seluruh request pengukuran latensi BMKG-only gagal."
    fi

    # --------------------------------------------------------------------------
    # TEST P2.2: Uji Concurrency & Burst 50 Koneksi Paralel (Tanpa Crash, Error < 1%)
    # --------------------------------------------------------------------------
    assert_start "P2.2" "Burst Concurrency (>= 50 Koneksi Paralel) & Stabilitas Server (Error Non-429 < 1%)"

    CONC_WORKERS=60
    TMP_RES_FILE=$(mktemp)

    echo -e "  ${YELLOW}ℹ Menjalankan ${CONC_WORKERS} koneksi paralel ke Client-Facing API...${NC}"
    for ((w=1; w<=CONC_WORKERS; w++)); do
        (
            T_START=$(now_ms)
            C_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${P2_TOKEN}" \
                -H "X-Correlation-ID: e2e-p2-burst-$w" \
                "${CLIENT_API_URL}/hazards?limit=10" || echo "000")
            T_END=$(now_ms)
            echo "${C_CODE} $((T_END - T_START))" >> "$TMP_RES_FILE"
        ) &
    done
    wait

    TOTAL_BURST=$(wc -l < "$TMP_RES_FILE" | tr -d ' ')
    OK_200=$(awk '$1 == "200" {c++} END {print c+0}' "$TMP_RES_FILE")
    REJ_429=$(awk '$1 == "429" {c++} END {print c+0}' "$TMP_RES_FILE")
    ERR_OTHER=$((TOTAL_BURST - OK_200 - REJ_429))
    rm -f "$TMP_RES_FILE"

    print_interaction_details \
        "GET (x${CONC_WORKERS} Parallel)" "${CLIENT_API_URL}/hazards?limit=10" \
        "Authorization: Bearer <ops-token>" "" \
        "Total=${TOTAL_BURST} | HTTP 200=${OK_200} | HTTP 429 (Controlled)=${REJ_429} | Uncontrolled Error=${ERR_OTHER}" \
        "Untuk sustained load test 60 detik penuh, jalankan: ./scripts/load-test/run-load-test.sh" \
        "Sistem tidak crash saat menerima >= 50 koneksi paralel, dengan error rate di luar 429 < 1%."

    if [[ "$ERR_OTHER" -eq 0 && "$TOTAL_BURST" -ge 50 ]]; then
        assert_pass "Seluruh ${TOTAL_BURST} koneksi paralel ditangani dengan aman (200 OK: ${OK_200}, 429 Controlled: ${REJ_429}, Uncontrolled Error: 0%)."
    else
        assert_fail "Ditemukan ${ERR_OTHER} error tak terkontrol dari ${TOTAL_BURST} koneksi paralel."
    fi

    # --------------------------------------------------------------------------
    # TEST P2.3a: Simulasi Outage PVMBG & Graceful Degradation (Data Stale + stale_since)
    # --------------------------------------------------------------------------
    assert_start "P2.3-OUTAGE" "Simulasi Outage PVMBG (POST /admin/outage): Graceful Degradation & Penanda stale_since"

    OUTAGE_ON_RESP=$(curl -s -w "\n%{http_code}" -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": true}' || echo -e "\n000")
    OUTAGE_ON_CODE=$(echo "$OUTAGE_ON_RESP" | tail -n 1)

    # Pastikan PVMBG benar-benar menolak request dengan 503 saat outage
    PVMBG_DIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" || echo "000")

    echo -e "  ${YELLOW}ℹ Menunggu siklus polling Aggregator mendeteksi kegagalan PVMBG (4 detik)...${NC}"
    sleep 4

    DEGRADED_SEISMIC_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${P2_TOKEN}" "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=5" || echo -e "\n000")
    DEGRADED_SEISMIC_CODE=$(echo "$DEGRADED_SEISMIC_RESP" | tail -n 1)

    DEGRADED_VOLC_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${P2_TOKEN}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=5" || echo -e "\n000")
    DEGRADED_VOLC_CODE=$(echo "$DEGRADED_VOLC_RESP" | tail -n 1)
    DEGRADED_VOLC_BODY=$(echo "$DEGRADED_VOLC_RESP" | sed '$d')

    BMKG_ST=$(echo "$DEGRADED_VOLC_BODY" | jq -r '.source_status.BMKG.status // "UNKNOWN"')
    PVMBG_ST=$(echo "$DEGRADED_VOLC_BODY" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
    PVMBG_STALE_SINCE=$(echo "$DEGRADED_VOLC_BODY" | jq -r '.source_status.PVMBG.stale_since // "null"')
    PVMBG_LAST_ERR=$(echo "$DEGRADED_VOLC_BODY" | jq -r '.source_status.PVMBG.last_error // "null"')
    CACHED_VOLC_LEN=$(echo "$DEGRADED_VOLC_BODY" | jq '.data | length' 2>/dev/null || echo "0")

    print_interaction_details \
        "POST -> GET" "${PVMBG_URL}/admin/outage (true) -> ${CLIENT_API_URL}/hazards?type=VOLCANIC" \
        "Authorization: Bearer <ops-token>" '{"outage": true}' \
        "PVMBG Direct=${PVMBG_DIRECT_CODE} | Client-API SEISMIC=${DEGRADED_SEISMIC_CODE} | Client-API VOLCANIC=${DEGRADED_VOLC_CODE}" \
        "source_status:\n$(echo "$DEGRADED_VOLC_BODY" | jq '.source_status' 2>/dev/null)\nJumlah record VOLCANIC dari Canonical Store: ${CACHED_VOLC_LEN}" \
        "Saat PVMBG mati (503), Client-API tetap mengembalikan 200 OK (bukan 500/timeout), data SEISMIC normal (BMKG=UP), dan data VOLCANIC diambil dari Canonical Store dengan PVMBG=DEGRADED & stale_since terisi."

    if [[ "$PVMBG_DIRECT_CODE" == "503" && "$DEGRADED_SEISMIC_CODE" == "200" && "$DEGRADED_VOLC_CODE" == "200" ]] && \
       [[ "$BMKG_ST" == "UP" && "$PVMBG_ST" == "DEGRADED" && "$PVMBG_STALE_SINCE" != "null" && "$CACHED_VOLC_LEN" -gt 0 ]]; then
        assert_pass "Graceful Degradation berhasil! BMKG=UP, PVMBG=DEGRADED (stale_since=${PVMBG_STALE_SINCE}, last_error='${PVMBG_LAST_ERR}'), ${CACHED_VOLC_LEN} record vulkanik disajikan dari Canonical Store."
    else
        assert_fail "Graceful degradation tidak sesuai kriteria: PVMBG_Direct=${PVMBG_DIRECT_CODE}, API_Code=${DEGRADED_VOLC_CODE}, BMKG=${BMKG_ST}, PVMBG=${PVMBG_ST}, stale_since=${PVMBG_STALE_SINCE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P2.3b: Pemulihan Otomatis Setelah Outage PVMBG Dimatikan Tanpa Restart
    # --------------------------------------------------------------------------
    assert_start "P2.3-RECOVERY" "Auto-Recovery PVMBG Setelah Outage Dimatikan Tanpa Restart"

    curl -s -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": false}' > /dev/null 2>&1 || true

    RECOVERED="false"
    REC_BODY=""
    for ((attempt=1; attempt<=10; attempt++)); do
        sleep 1
        REC_BODY=$(curl -s -H "Authorization: Bearer ${P2_TOKEN}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
        CUR_ST=$(echo "$REC_BODY" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
        CUR_STALE=$(echo "$REC_BODY" | jq -r '.source_status.PVMBG.stale_since // "null"')
        if [[ "$CUR_ST" == "UP" && "$CUR_STALE" == "null" ]]; then
            RECOVERED="true"
            break
        fi
    done

    print_interaction_details \
        "POST -> GET" "${PVMBG_URL}/admin/outage (false) -> ${CLIENT_API_URL}/hazards" \
        "Authorization: Bearer <ops-token>" '{"outage": false}' \
        "Recovered=${RECOVERED}" \
        "source_status setelah recovery:\n$(echo "$REC_BODY" | jq '.source_status' 2>/dev/null)" \
        "Setelah outage dimatikan, status PVMBG kembali menjadi UP dan stale_since kembali null secara otomatis tanpa restart."

    if [[ "$RECOVERED" == "true" ]]; then
        assert_pass "Sistem pulih otomatis ke status UP (stale_since=null) tanpa restart service mana pun."
    else
        assert_fail "Sistem gagal pulih ke status UP setelah outage dimatikan."
    fi
fi

# ==============================================================================
# BAGIAN 3: PROBLEM 3 — SERVICE-TO-SERVICE AUTHENTICATION & TRUST
# ==============================================================================
if should_run "p3"; then
    print_section "BAGIAN 3: PROBLEM 3 — SERVICE-TO-SERVICE AUTHENTICATION & TRUST"

    # --------------------------------------------------------------------------
    # TEST P3.1: Pemisahan Domain of Trust Instansi (BMKG vs PVMBG)
    # --------------------------------------------------------------------------
    assert_start "P3.1" "Isolasi Kredensial Antar Instansi (BMKG Key Ditolak PVMBG & PVMBG Token Ditolak BMKG)"

    # 1. Kredensial BMKG dikirim ke PVMBG (harus 401/403)
    CROSS_1_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-BMKG-Key: ${BMKG_API_KEY}" "${PVMBG_URL}/volcanic-reports" || echo "000")
    # 2. Kredensial BMKG disisipkan sebagai Bearer ke PVMBG (harus 401/403)
    CROSS_2_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${BMKG_API_KEY}" "${PVMBG_URL}/volcanic-reports" || echo "000")
    # 3. Kredensial PVMBG dikirim ke BMKG sebagai Bearer (harus 401/403)
    CROSS_3_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${PVMBG_TOKEN}" "${BMKG_URL}/seismic-events" || echo "000")
    # 4. Kredensial PVMBG dikirim ke BMKG sebagai X-BMKG-Key (harus 401/403)
    CROSS_4_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-BMKG-Key: ${PVMBG_TOKEN}" "${BMKG_URL}/seismic-events" || echo "000")
    # 5. Tanpa kredensial ke kedua mock (harus 401/403)
    NO_CRED_BMKG=$(curl -s -o /dev/null -w "%{http_code}" "${BMKG_URL}/seismic-events" || echo "000")
    NO_CRED_PVMBG=$(curl -s -o /dev/null -w "%{http_code}" "${PVMBG_URL}/volcanic-reports" || echo "000")

    print_interaction_details \
        "GET (Cross-Domain Auth)" "BMKG (:8081) & PVMBG (:8082)" \
        "Cross-credential & No-credential tests" "" \
        "BMKG_Key->PVMBG=${CROSS_1_CODE}/${CROSS_2_CODE} | PVMBG_Token->BMKG=${CROSS_3_CODE}/${CROSS_4_CODE} | NoCred=${NO_CRED_BMKG}/${NO_CRED_PVMBG}" \
        "1. X-BMKG-Key ke PVMBG           -> HTTP ${CROSS_1_CODE}\n2. Bearer <bmkg-key> ke PVMBG    -> HTTP ${CROSS_2_CODE}\n3. Bearer <pvmbg-token> ke BMKG  -> HTTP ${CROSS_3_CODE}\n4. X-BMKG-Key <pvmbg> ke BMKG    -> HTTP ${CROSS_4_CODE}\n5. Tanpa Header ke BMKG & PVMBG  -> HTTP ${NO_CRED_BMKG} & ${NO_CRED_PVMBG}" \
        "Seluruh percobaan lintas kredensial maupun tanpa kredensial wajib ditolak dengan HTTP 401/403."

    if [[ "$CROSS_1_CODE" =~ ^(401|403)$ && "$CROSS_2_CODE" =~ ^(401|403)$ && \
          "$CROSS_3_CODE" =~ ^(401|403)$ && "$CROSS_4_CODE" =~ ^(401|403)$ && \
          "$NO_CRED_BMKG" =~ ^(401|403)$ && "$NO_CRED_PVMBG" =~ ^(401|403)$ ]]; then
        assert_pass "Pemisahan domain of trust BMKG & PVMBG terbukti: seluruh kredensial silang ditolak (401 Unauthorized)."
    else
        assert_fail "Terdapat celah validasi kredensial instansi: ${CROSS_1_CODE}, ${CROSS_2_CODE}, ${CROSS_3_CODE}, ${CROSS_4_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.2a: Auth Service — Penerbitan Token 3 Identitas Berbeda & Uji Negatif
    # --------------------------------------------------------------------------
    assert_start "P3.2-AUTH" "Auth Service: Penerbitan Token 3 Client Berbeda (Media, Field Team, BNPB Ops) & Penolakan Kredensial Salah"

    # Negative cases pada POST /token
    BAD_GRANT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d '{"grant_type":"password","client_id":"media-client","client_secret":"xxx"}' || echo "000")
    BAD_SECRET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"wrong-secret\"}" || echo "000")

    # Positive cases: Media, Field Team, BNPB Ops
    MEDIA_TOK_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"${CLIENT_MEDIA_SECRET}\"}" || echo -e "\n000")
    MEDIA_TOK_CODE=$(echo "$MEDIA_TOK_RESP" | tail -n 1)
    MEDIA_TOK_BODY=$(echo "$MEDIA_TOK_RESP" | sed '$d')
    MEDIA_ACCESS_TOKEN=$(echo "$MEDIA_TOK_BODY" | jq -r '.access_token // ""')
    MEDIA_SCOPE=$(echo "$MEDIA_TOK_BODY" | jq -r '.scope // ""')

    FIELD_TOK_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"${CLIENT_FIELD_SECRET}\"}" || echo -e "\n000")
    FIELD_TOK_CODE=$(echo "$FIELD_TOK_RESP" | tail -n 1)
    FIELD_TOK_BODY=$(echo "$FIELD_TOK_RESP" | sed '$d')
    FIELD_ACCESS_TOKEN=$(echo "$FIELD_TOK_BODY" | jq -r '.access_token // ""')
    FIELD_REFRESH_TOKEN=$(echo "$FIELD_TOK_BODY" | jq -r '.refresh_token // ""')
    FIELD_SCOPE=$(echo "$FIELD_TOK_BODY" | jq -r '.scope // ""')
    FIELD_EXPIRES_IN=$(echo "$FIELD_TOK_BODY" | jq -r '.expires_in // 0')

    OPS_TOK_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}" || echo -e "\n000")
    OPS_TOK_CODE=$(echo "$OPS_TOK_RESP" | tail -n 1)
    OPS_TOK_BODY=$(echo "$OPS_TOK_RESP" | sed '$d')
    OPS_ACCESS_TOKEN=$(echo "$OPS_TOK_BODY" | jq -r '.access_token // ""')
    OPS_SCOPE=$(echo "$OPS_TOK_BODY" | jq -r '.scope // ""')

    print_interaction_details \
        "POST" "${AUTH_URL}/token" \
        "Content-Type: application/json" \
        "3 Identitas Client: ${CLIENT_MEDIA_ID}, ${CLIENT_FIELD_ID}, ${CLIENT_OPS_ID}" \
        "Media=${MEDIA_TOK_CODE}, Field=${FIELD_TOK_CODE}, Ops=${OPS_TOK_CODE}, BadSecret=${BAD_SECRET_CODE}, BadGrant=${BAD_GRANT_CODE}" \
        "Media Scope     : ${MEDIA_SCOPE}\nField Team Scope: ${FIELD_SCOPE} (TTL=${FIELD_EXPIRES_IN}s)\nBNPB Ops Scope  : ${OPS_SCOPE}" \
        "Ketiga client memiliki kredensial & identitas berbeda: Media mendapat scope 'hazards:read:summary', Field Team & Ops mendapat 'hazards:read:raw' dengan TTL pendek (${ACCESS_TOKEN_TTL}s)."

    if [[ "$MEDIA_TOK_CODE" == "200" && "$MEDIA_SCOPE" == "hazards:read:summary" && \
          "$FIELD_TOK_CODE" == "200" && "$FIELD_SCOPE" == "hazards:read:raw" && \
          "$OPS_TOK_CODE" == "200" && "$OPS_SCOPE" == "hazards:read:raw" && \
          "$BAD_SECRET_CODE" == "401" && "$BAD_GRANT_CODE" == "400" ]]; then
        assert_pass "Auth Service menerbitkan token dengan scope & TTL tepat untuk ketiga client dan menolak kredensial salah (401)."
    else
        assert_fail "Penerbitan atau validasi token Auth Service gagal."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.2b: Penegakan Scope Media (Hanya Field Ringkasan, 0 Kebocoran Field Mentah)
    # --------------------------------------------------------------------------
    assert_start "P3.2-MEDIA-SUMMARY" "Penegakan Scope Media pada GET /hazards & GET /hazards/{id} (Hanya Field Ringkasan)"

    NO_TOK_RESP=$(curl -s -w "\n%{http_code}" "${CLIENT_API_URL}/hazards" || echo -e "\n000")
    NO_TOK_CODE=$(echo "$NO_TOK_RESP" | tail -n 1)
    NO_TOK_ERR=$(echo "$NO_TOK_RESP" | sed '$d' | jq -r '.error.code // ""')

    FAKE_TOK_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer token.palsu.tidakvalid" "${CLIENT_API_URL}/hazards" || echo -e "\n000")
    FAKE_TOK_CODE=$(echo "$FAKE_TOK_RESP" | tail -n 1)
    FAKE_TOK_ERR=$(echo "$FAKE_TOK_RESP" | sed '$d' | jq -r '.error.code // ""')

    MEDIA_LIST_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=10" || echo -e "\n000")
    MEDIA_LIST_CODE=$(echo "$MEDIA_LIST_RESP" | tail -n 1)
    MEDIA_LIST_BODY=$(echo "$MEDIA_LIST_RESP" | sed '$d')

    SAMPLE_HAZARD_ID=$(echo "$MEDIA_LIST_BODY" | jq -r '.data[0].hazard_id // "BMKG-bmkg-0001"')

    MEDIA_DETAIL_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/${SAMPLE_HAZARD_ID}" || echo -e "\n000")
    MEDIA_DETAIL_CODE=$(echo "$MEDIA_DETAIL_RESP" | tail -n 1)
    MEDIA_DETAIL_BODY=$(echo "$MEDIA_DETAIL_RESP" | sed '$d')

    # Pastikan TIDAK ADA field Mentah (source_ref_id, latitude, longitude, attributes) di list maupun detail
    LEAK_LIST=$(echo "$MEDIA_LIST_BODY" | jq '[.data[] | select(has("source_ref_id") or has("latitude") or has("longitude") or has("attributes"))] | length' 2>/dev/null || echo "99")
    LEAK_DETAIL=$(echo "$MEDIA_DETAIL_BODY" | jq '.data | (has("source_ref_id") or has("latitude") or has("longitude") or has("attributes"))' 2>/dev/null || echo "true")

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards & /hazards/${SAMPLE_HAZARD_ID}" \
        "Authorization: Bearer <media-token>" "" \
        "NoToken=${NO_TOK_CODE} (${NO_TOK_ERR}) | FakeToken=${FAKE_TOK_CODE} (${FAKE_TOK_ERR}) | MediaList=${MEDIA_LIST_CODE} | MediaDetail=${MEDIA_DETAIL_CODE}" \
        "Sample Media Item (Ringkasan Saja):\n$(echo "$MEDIA_DETAIL_BODY" | jq '.data' 2>/dev/null)" \
        "Media hanya menerima 7 field Ringkasan (hazard_id, source, hazard_type, severity, area_name, occurred_at, ingested_at) tanpa kebocoran source_ref_id, latitude, longitude, atau attributes."

    if [[ "$NO_TOK_CODE" == "401" && "$FAKE_TOK_CODE" == "401" && "$MEDIA_LIST_CODE" == "200" && "$MEDIA_DETAIL_CODE" == "200" && "$LEAK_LIST" -eq 0 && "$LEAK_DETAIL" == "false" ]]; then
        assert_pass "Scope Media terproteksi penuh: 0 kebocoran field mentah pada list maupun detail, serta request tanpa/salah token ditolak 401."
    else
        assert_fail "Pelanggaran scope Media! LeakList=${LEAK_LIST}, LeakDetail=${LEAK_DETAIL}, MediaList=${MEDIA_LIST_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.2c: Penolakan Eksplisit Permintaan Field Mentah oleh Media (403 INSUFFICIENT_SCOPE)
    # --------------------------------------------------------------------------
    assert_start "P3.2-MEDIA-FORBIDDEN" "Penolakan Server (403 INSUFFICIENT_SCOPE) Saat Media Meminta Field Mentah Secara Eksplisit"

    # 1. Media meminta ?fields=severity,latitude (campuran ringkasan + mentah)
    M_FIELD_1_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?fields=severity,latitude" || echo -e "\n000")
    M_FIELD_1_CODE=$(echo "$M_FIELD_1_RESP" | tail -n 1)
    M_FIELD_1_ERR=$(echo "$M_FIELD_1_RESP" | sed '$d' | jq -r '.error.code // ""')

    # 2. Media meminta ?fields=attributes
    M_FIELD_2_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?fields=attributes" || echo -e "\n000")
    M_FIELD_2_CODE=$(echo "$M_FIELD_2_RESP" | tail -n 1)

    # 3. Media mengakses endpoint /hazards/{id}/raw
    M_RAW_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/${SAMPLE_HAZARD_ID}/raw" || echo -e "\n000")
    M_RAW_CODE=$(echo "$M_RAW_RESP" | tail -n 1)
    M_RAW_BODY=$(echo "$M_RAW_RESP" | sed '$d')
    M_RAW_ERR=$(echo "$M_RAW_BODY" | jq -r '.error.code // ""')

    # 4. Media meminta subset field Ringkasan saja (?fields=hazard_id,severity,area_name) -> Harus 200 OK
    M_SUM_SUBSET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?fields=hazard_id,severity,area_name&limit=2" || echo "000")

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards?fields=severity,latitude & /hazards/${SAMPLE_HAZARD_ID}/raw" \
        "Authorization: Bearer <media-token>" "" \
        "fields=severity,latitude -> ${M_FIELD_1_CODE} (${M_FIELD_1_ERR}) | fields=attributes -> ${M_FIELD_2_CODE} | /raw -> ${M_RAW_CODE} (${M_RAW_ERR}) | summary-subset -> ${M_SUM_SUBSET_CODE}" \
        "Response Penolakan /raw:\n${M_RAW_BODY}" \
        "Permintaan eksplisit terhadap field Mentah oleh Media wajib ditolak server dengan 403 INSUFFICIENT_SCOPE."

    if [[ "$M_FIELD_1_CODE" == "403" && "$M_FIELD_1_ERR" == "INSUFFICIENT_SCOPE" && \
          "$M_FIELD_2_CODE" == "403" && "$M_RAW_CODE" == "403" && "$M_RAW_ERR" == "INSUFFICIENT_SCOPE" && \
          "$M_SUM_SUBSET_CODE" == "200" ]]; then
        assert_pass "Server secara aktif menolak permintaan field mentah dari Media dengan HTTP 403 INSUFFICIENT_SCOPE."
    else
        assert_fail "Penolakan eksplisit field mentah Media gagal: F1=${M_FIELD_1_CODE}, F2=${M_FIELD_2_CODE}, Raw=${M_RAW_CODE}, Subset=${M_SUM_SUBSET_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.2d: Hak Akses Penuh Tim Lapangan & BNPB Ops (Seluruh Field Termasuk Mentah)
    # --------------------------------------------------------------------------
    assert_start "P3.2-RAW-ACCESS" "Akses Penuh Tim Lapangan (field-team) & BNPB Pusat (bnpb-ops) terhadap Field Mentah"

    FIELD_LIST_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${FIELD_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5" || echo -e "\n000")
    FIELD_LIST_CODE=$(echo "$FIELD_LIST_RESP" | tail -n 1)
    FIELD_LIST_BODY=$(echo "$FIELD_LIST_RESP" | sed '$d')

    FIELD_RAW_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${FIELD_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/${SAMPLE_HAZARD_ID}/raw" || echo -e "\n000")
    FIELD_RAW_CODE=$(echo "$FIELD_RAW_RESP" | tail -n 1)
    FIELD_RAW_BODY=$(echo "$FIELD_RAW_RESP" | sed '$d')

    OPS_RAW_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/${SAMPLE_HAZARD_ID}/raw" || echo -e "\n000")
    OPS_RAW_CODE=$(echo "$OPS_RAW_RESP" | tail -n 1)

    HAS_ALL_RAW=$(echo "$FIELD_RAW_BODY" | jq '.data | (has("source_ref_id") and has("latitude") and has("longitude") and has("attributes"))' 2>/dev/null || echo "false")

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards & /hazards/${SAMPLE_HAZARD_ID}/raw" \
        "Authorization: Bearer <field-team-token> & <bnpb-ops-token>" "" \
        "FieldList=${FIELD_LIST_CODE} | FieldRaw=${FIELD_RAW_CODE} | OpsRaw=${OPS_RAW_CODE}" \
        "Response /raw untuk Tim Lapangan:\n$(echo "$FIELD_RAW_BODY" | jq '.data' 2>/dev/null)" \
        "Tim Lapangan dan BNPB Ops berhak mengakses seluruh field termasuk source_ref_id, latitude, longitude, dan attributes (200 OK)."

    if [[ "$FIELD_LIST_CODE" == "200" && "$FIELD_RAW_CODE" == "200" && "$OPS_RAW_CODE" == "200" && "$HAS_ALL_RAW" == "true" ]]; then
        assert_pass "Tim Lapangan & BNPB Ops berhasil menerima seluruh field termasuk field Mentah (200 OK)."
    else
        assert_fail "Akses field mentah untuk Tim Lapangan / Ops gagal."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.3: Kedaluwarsa Alami Access Token Tim Lapangan (TTL 60s) & Refresh Flow Tanpa Login Ulang
    # --------------------------------------------------------------------------
    assert_start "P3.3" "Kedaluwarsa Access Token Tim Lapangan (TTL ${ACCESS_TOKEN_TTL}s), Refresh Tanpa Login Ulang, & Rotasi Single-Use"

    # Terbitkan token segar khusus untuk diuji siklus hidupnya
    FRESH_F_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"${CLIENT_FIELD_SECRET}\"}")
    ACTIVE_F_ACCESS=$(echo "$FRESH_F_RESP" | jq -r '.access_token // ""')
    ACTIVE_F_REFRESH=$(echo "$FRESH_F_RESP" | jq -r '.refresh_token // ""')
    ACTIVE_F_TTL=$(echo "$FRESH_F_RESP" | jq -r '.expires_in // 60')

    # Verifikasi token aktif saat awal sesi
    INITIAL_SES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${ACTIVE_F_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1" || echo "000")

    EXPIRED_CODE="SKIPPED_FAST_MODE"
    EXPIRED_ERR_CODE="SKIPPED_FAST_MODE"
    if [[ "$FAST_MODE" == "false" ]]; then
        WAIT_SEC=$((ACTIVE_F_TTL + 2))
        echo -e "  ${YELLOW}⏳ Menunggu ${WAIT_SEC} detik agar access token Tim Lapangan kedaluwarsa secara alami (Kriteria P3.3)...${NC}"
        for ((s=1; s<=WAIT_SEC; s++)); do
            if (( s % 10 == 0 || s == WAIT_SEC )); then
                echo -e "     ... ${s}/${WAIT_SEC} detik berlalu"
            fi
            sleep 1
        done
        EXP_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${ACTIVE_F_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1" || echo -e "\n000")
        EXPIRED_CODE=$(echo "$EXP_RESP" | tail -n 1)
        EXPIRED_ERR_CODE=$(echo "$EXP_RESP" | sed '$d' | jq -r '.error.code // ""')
    fi

    # Refresh token tanpa login ulang manual (hanya mengirim refresh_token)
    REFRESH_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"${ACTIVE_F_REFRESH}\"}" || echo -e "\n000")
    REFRESH_CODE=$(echo "$REFRESH_RESP" | tail -n 1)
    REFRESH_BODY=$(echo "$REFRESH_RESP" | sed '$d')
    NEW_F_ACCESS=$(echo "$REFRESH_BODY" | jq -r '.access_token // ""')
    NEW_F_REFRESH=$(echo "$REFRESH_BODY" | jq -r '.refresh_token // ""')

    # Gunakan access token baru untuk melanjutkan sesi
    RESUMED_SES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${NEW_F_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1" || echo "000")

    # Coba gunakan ulang refresh token lama (wajib ditolak 401 karena single-use rotation)
    REPLAY_REFRESH_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"${ACTIVE_F_REFRESH}\"}" || echo -e "\n000")
    REPLAY_REFRESH_CODE=$(echo "$REPLAY_REFRESH_RESP" | tail -n 1)
    REPLAY_REFRESH_BODY=$(echo "$REPLAY_REFRESH_RESP" | sed '$d')

    print_interaction_details \
        "GET -> WAIT -> GET -> POST /refresh -> GET" "${CLIENT_API_URL}/hazards & ${AUTH_URL}/refresh" \
        "Field Team Session Lifecycle" "{\"refresh_token\":\"${ACTIVE_F_REFRESH:0:16}...\"}" \
        "Initial=${INITIAL_SES_CODE} | AfterTTL=${EXPIRED_CODE} (${EXPIRED_ERR_CODE}) | Refresh=${REFRESH_CODE} | NewTokenUse=${RESUMED_SES_CODE} | OldRefreshReplay=${REPLAY_REFRESH_CODE}" \
        "Refresh Response:\n${REFRESH_BODY}\nReplay Old Refresh Token Response:\n${REPLAY_REFRESH_BODY}" \
        "Setelah TTL habis, access token lama ditolak (401 TOKEN_EXPIRED), POST /refresh menerbitkan token baru tanpa kredensial client (200 OK), dan refresh token lama ditolak saat dipakai ulang (401)."

    if [[ "$INITIAL_SES_CODE" == "200" && "$REFRESH_CODE" == "200" && "$RESUMED_SES_CODE" == "200" && "$REPLAY_REFRESH_CODE" == "401" ]] && \
       [[ "$FAST_MODE" == "true" || ( "$EXPIRED_CODE" == "401" && "$EXPIRED_ERR_CODE" == "TOKEN_EXPIRED" ) ]]; then
        assert_pass "Siklus TTL & Refresh Token berhasil! Initial=200, Expired=${EXPIRED_CODE}(${EXPIRED_ERR_CODE}), Refresh=200, NewAccess=200, ReplayOldRefresh=401."
    else
        assert_fail "Siklus kedaluwarsa/refresh token gagal: Initial=${INITIAL_SES_CODE}, Expired=${EXPIRED_CODE}(${EXPIRED_ERR_CODE}), Refresh=${REFRESH_CODE}, NewUse=${RESUMED_SES_CODE}, Replay=${REPLAY_REFRESH_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P3.4: Audit Keamanan Kredensial & Keberadaan .env.example
    # --------------------------------------------------------------------------
    assert_start "P3.4" "Audit Keamanan Kredensial: Keberadaan .env.example, Git Ignore .env, & Zero Hardcoded Secrets"

    REQUIRED_ENV_EXAMPLES=(
        ".env.example"
        "services/bmkg-mock/.env.example"
        "services/pvmbg-mock/.env.example"
        "services/aggregator/.env.example"
        "services/client-api/.env.example"
        "services/auth-service/.env.example"
        "services/message-broker/.env.example"
        "services/consumer-dashboard/.env.example"
        "services/consumer-notifier/.env.example"
    )

    MISSING_EXAMPLES=()
    for rel in "${REQUIRED_ENV_EXAMPLES[@]}"; do
        if [[ ! -f "${PROJECT_ROOT}/${rel}" ]]; then
            MISSING_EXAMPLES+=("$rel")
        fi
    done

    # Cek apakah ada file .env (selain .env.example) yang ter-track di Git
    TRACKED_ENV_FILES=$(cd "$PROJECT_ROOT" && git ls-files | grep -E '(^|/)\.env$' || true)

    # Cek apakah docker-compose.yml atau file .go non-test memuat kredensial literal
    HARDCODED_IN_COMPOSE=$(grep -E "bmkg-secret-key-123|pvmbg-secret-token-456|bnpbpass123|POSTGRES_PASSWORD:[[:space:]]*aggregator_pass" "${PROJECT_ROOT}/docker-compose.yml" || true)
    HARDCODED_IN_GO=$(grep -rnE "bmkg-secret-key-123|pvmbg-secret-token-456|bnpbpass123" "${PROJECT_ROOT}/services" --include="*.go" | grep -v "_test.go" || true)

    print_interaction_details \
        "STATIC AUDIT" "Git Tracking, .env.example, docker-compose.yml, & services/**/*.go" \
        "Ketentuan Poin 6 & Kriteria P3.4" "" \
        "MissingExamples=${#MISSING_EXAMPLES[@]} | TrackedEnvFiles=$([[ -z "$TRACKED_ENV_FILES" ]] && echo 0 || echo 1) | HardcodedCompose=$([[ -z "$HARDCODED_IN_COMPOSE" ]] && echo 0 || echo 1) | HardcodedGo=$([[ -z "$HARDCODED_IN_GO" ]] && echo 0 || echo 1)" \
        "Checked .env.example files: ${#REQUIRED_ENV_EXAMPLES[@]} files verified.\nTracked .env in git: ${TRACKED_ENV_FILES:-NONE}\nHardcoded in docker-compose.yml: ${HARDCODED_IN_COMPOSE:-NONE}\nHardcoded in Go source: ${HARDCODED_IN_GO:-NONE}" \
        "Seluruh .env.example tersedia, tidak ada file .env yang ter-commit di git, dan tidak ada kredensial ter-hardcode di kode maupun docker-compose.yml."

    if [[ "${#MISSING_EXAMPLES[@]}" -eq 0 && -z "$TRACKED_ENV_FILES" && -z "$HARDCODED_IN_COMPOSE" && -z "$HARDCODED_IN_GO" ]]; then
        assert_pass "Audit P3.4 LULUS 100%: Seluruh ${#REQUIRED_ENV_EXAMPLES[@]} berkas .env.example lengkap, 0 file .env ter-commit, dan 0 kredensial hardcoded."
    else
        assert_fail "Audit P3.4 gagal! Missing=${MISSING_EXAMPLES[*]:-none}, TrackedEnv=${TRACKED_ENV_FILES:-none}, ComposeHardcode=${HARDCODED_IN_COMPOSE:-none}, GoHardcode=${HARDCODED_IN_GO:-none}."
    fi
fi

# ==============================================================================
# BAGIAN 4: PROBLEM 4 — ARSITEKTUR MICROSERVICE & FLEXIBLE STORAGE
# ==============================================================================
if should_run "p4"; then
    print_section "BAGIAN 4: PROBLEM 4 — ARSITEKTUR MICROSERVICE & FLEXIBLE STORAGE"

    # Pastikan kita punya token Ops
    if [[ -z "$OPS_ACCESS_TOKEN" ]]; then
        P4_TOK_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}")
        OPS_ACCESS_TOKEN=$(echo "$P4_TOK_RESP" | jq -r '.access_token // ""')
    fi

    # --------------------------------------------------------------------------
    # TEST P4.2: Penyimpanan Fleksibel JSONB Tanpa Migrasi (Koeksistensi Skema Lama & Baru)
    # --------------------------------------------------------------------------
    assert_start "P4.2" "Flexible Storage (PostgreSQL JSONB): Koeksistensi Record Sebelum & Sesudah confidence_level Tanpa Migrasi"

    # Pastikan terdapat record baik dengan maupun tanpa confidence_level
    P4_VOLC_RESP=$(curl -s -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100" || echo "{}")
    NEW_SCHEMA_CNT=$(echo "$P4_VOLC_RESP" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
    if [[ "$NEW_SCHEMA_CNT" -eq 0 ]]; then
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${PVMBG_TOKEN}" \
            -d '{"enabled": true}' > /dev/null 2>&1 || true
        for ((wait_p4=1; wait_p4<=9; wait_p4++)); do
            sleep 2
            P4_VOLC_RESP=$(curl -s -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100" || echo "{}")
            NEW_SCHEMA_CNT=$(echo "$P4_VOLC_RESP" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
            if [[ "$NEW_SCHEMA_CNT" -gt 0 ]]; then
                break
            fi
        done
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${PVMBG_TOKEN}" \
            -d '{"enabled": false}' > /dev/null 2>&1 || true
    fi

    OLD_SCHEMA_CNT=$(echo "$P4_VOLC_RESP" | jq '[.data[] | select(.attributes.confidence_level == null)] | length' 2>/dev/null || echo "0")

    OLD_SAMPLE_ITEM=$(echo "$P4_VOLC_RESP" | jq -c '[.data[] | select(.attributes.confidence_level == null)][0] | {hazard_id, occurred_at, attributes}' 2>/dev/null || echo "{}")
    NEW_SAMPLE_ITEM=$(echo "$P4_VOLC_RESP" | jq -c '[.data[] | select(.attributes.confidence_level != null)][0] | {hazard_id, occurred_at, attributes}' 2>/dev/null || echo "{}")

    DB_PROOF_OUTPUT="Skipped direct DB query (--no-docker)"
    if [[ "$NO_DOCKER" == "false" ]]; then
        DB_PROOF_OUTPUT=$(cd "$PROJECT_ROOT" && docker compose exec -T canonical-store psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
            "SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' ORDER BY (attributes ? 'confidence_level') DESC, occurred_at DESC LIMIT 6;" 2>/dev/null || echo "Gagal query psql")
        if [[ "$SAVE_REPORT" == "true" ]]; then
            {
                echo "=== BUKTI P4.2 FLEXIBLE STORAGE (POSTGRESQL JSONB) ==="
                echo "$DB_PROOF_OUTPUT"
                echo ""
            } >> "$EVIDENCE_FILE"
        fi
    fi

    print_interaction_details \
        "GET & SQL" "${CLIENT_API_URL}/hazards?type=VOLCANIC & PostgreSQL hazard_events (JSONB)" \
        "Authorization: Bearer <ops-token>" "" \
        "OldSchemaRecords=${OLD_SCHEMA_CNT} | NewSchemaRecords=${NEW_SCHEMA_CNT}" \
        "Record Sebelum Perubahan Skema : ${OLD_SAMPLE_ITEM}\nRecord Sesudah Perubahan Skema : ${NEW_SAMPLE_ITEM}\n\nQuery Tabel hazard_events di Canonical Store:\n${DB_PROOF_OUTPUT}" \
        "Record dari sebelum dan sesudah munculnya confidence_level tersimpan berdampingan tanpa migrasi tabel dan keduanya dapat dibaca."

    if [[ "$OLD_SCHEMA_CNT" -gt 0 && "$NEW_SCHEMA_CNT" -gt 0 ]]; then
        assert_pass "Koeksistensi data terbukti: ${OLD_SCHEMA_CNT} record skema lama dan ${NEW_SCHEMA_CNT} record skema baru tersimpan berdampingan & terbaca via API."
    else
        assert_fail "Gagal membuktikan koeksistensi skema lama (${OLD_SCHEMA_CNT}) dan baru (${NEW_SCHEMA_CNT})."
    fi

    # --------------------------------------------------------------------------
    # TEST P4.3: Kepemilikan Penyimpanan Eksklusif, Filter Query, & Pagination Cursor
    # --------------------------------------------------------------------------
    assert_start "P4.3" "Kepemilikan Canonical Store (Hanya Diakses Aggregator) & Validasi Filter/Cursor/Error API"

    # 1. Cek bahwa client-api di docker-compose tidak memiliki akses langsung ke canonical-store (tidak ada DATABASE_URL)
    CLIENT_API_HAS_DB=$(grep -A 15 "client-api:" "${PROJECT_ROOT}/docker-compose.yml" | grep "DATABASE_URL" || true)
    CLIENT_ENV_HAS_DB=$(grep "DATABASE_URL" "${PROJECT_ROOT}/services/client-api/.env.example" || true)

    # 2. Uji pagination cursor dan filter pada Client-API (yang meneruskan ke Aggregator)
    PAGE1_RESP=$(curl -s -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5" || echo "{}")
    PAGE1_CNT=$(echo "$PAGE1_RESP" | jq '.data | length' 2>/dev/null || echo "0")
    NEXT_CUR=$(echo "$PAGE1_RESP" | jq -r '.next_cursor // ""')

    PAGE2_CNT=0
    OVERLAP_CNT=0
    if [[ -n "$NEXT_CUR" && "$NEXT_CUR" != "null" ]]; then
        PAGE2_RESP=$(curl -s -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5&cursor=${NEXT_CUR}" || echo "{}")
        PAGE2_CNT=$(echo "$PAGE2_RESP" | jq '.data | length' 2>/dev/null || echo "0")
        OVERLAP_CNT=$(jq -n --argjson p1 "$(echo "$PAGE1_RESP" | jq '.data | map(.hazard_id)')" \
                            --argjson p2 "$(echo "$PAGE2_RESP" | jq '.data | map(.hazard_id)')" \
                            '$p1 - ($p1 - $p2) | length' 2>/dev/null || echo "0")
    fi

    # 3. Uji validasi parameter invalid (400 INVALID_PARAMETER) dan ID tidak ditemukan (404 NOT_FOUND)
    BAD_LIMIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=999" || echo "000")
    BAD_CURSOR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?cursor=cursor_rusak_123" || echo "000")
    NOT_FOUND_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/BMKG-tidak-ada-99999" || echo "000")

    print_interaction_details \
        "GET & ARCH CHECK" "${CLIENT_API_URL}/hazards (Cursor Pagination, Filter, Error Handling, & DB Ownership)" \
        "Ketentuan Poin 2 & Kriteria P4.3" "" \
        "Page1=${PAGE1_CNT} | Page2=${PAGE2_CNT} (Overlap=${OVERLAP_CNT}) | BadLimit=${BAD_LIMIT_CODE} | BadCursor=${BAD_CURSOR_CODE} | NotFound=${NOT_FOUND_CODE}" \
        "Client-API DATABASE_URL config: ${CLIENT_API_HAS_DB:-NONE (Isolated - reads via AGGREGATOR_URL)}\nNext Cursor Sample: ${NEXT_CUR}" \
        "Canonical Store hanya diakses oleh Aggregator, Client-API meminta lewat API Aggregator, keyset pagination bebas duplikasi, dan parameter salah dijawab 400/404."

    if [[ -z "$CLIENT_API_HAS_DB" && -z "$CLIENT_ENV_HAS_DB" && "$PAGE1_CNT" -eq 5 && "$PAGE2_CNT" -gt 0 && "$OVERLAP_CNT" -eq 0 && \
          "$BAD_LIMIT_CODE" == "400" && "$BAD_CURSOR_CODE" == "400" && "$NOT_FOUND_CODE" == "404" ]]; then
        assert_pass "Kepemilikan Canonical Store eksklusif pada Aggregator, keyset pagination berjalan akurat (0 overlap), dan validasi 400/404 sesuai kontrak."
    else
        assert_fail "Validasi P4.3 gagal: Page1=${PAGE1_CNT}, Page2=${PAGE2_CNT}, Overlap=${OVERLAP_CNT}, BadLimit=${BAD_LIMIT_CODE}, BadCursor=${BAD_CURSOR_CODE}, NotFound=${NOT_FOUND_CODE}."
    fi

    # --------------------------------------------------------------------------
    # TEST P4.1a: Independensi Container — Saat auth-service Mati, client-api Tetap Melayani Request
    # --------------------------------------------------------------------------
    assert_start "P4.1-AUTH-INDEP" "Independensi Microservice: Saat auth-service Dihentikan, client-api Tetap Melayani Request dengan Token Aktif"

    if [[ "$NO_DOCKER" == "true" ]]; then
        assert_skip "Dilewati karena flag --no-docker aktif."
    else
        # Ambil token segar sebelum auth-service dihentikan
        PRE_STOP_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}")
        OPS_ACCESS_TOKEN=$(echo "$PRE_STOP_RESP" | jq -r '.access_token // ""')

        (cd "$PROJECT_ROOT" && docker compose stop auth-service > /dev/null 2>&1)
        AUTH_DOWN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "${AUTH_URL}/health" || true)
        [[ -z "$AUTH_DOWN_CODE" ]] && AUTH_DOWN_CODE="000"

        # Client-API memverifikasi JWT menggunakan kunci publik Ed25519 lokal tanpa memanggil auth-service
        API_WHILE_AUTH_DOWN=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=3" || echo -e "\n000")
        API_WHILE_AUTH_DOWN_CODE=$(echo "$API_WHILE_AUTH_DOWN" | tail -n 1)

        (cd "$PROJECT_ROOT" && docker compose start auth-service > /dev/null 2>&1)
        # Tunggu auth-service kembali sehat
        for _ in {1..10}; do
            if [[ "$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}/health" || true)" == "200" ]]; then
                break
            fi
            sleep 1
        done

        print_interaction_details \
            "docker compose stop auth-service -> GET /hazards" "${CLIENT_API_URL}/hazards?limit=3" \
            "Authorization: Bearer <ops-token> (Verifikasi Ed25519 Asimetris)" "" \
            "AuthHealthWhileStopped=${AUTH_DOWN_CODE} | ClientAPIWhileAuthStopped=${API_WHILE_AUTH_DOWN_CODE}" \
            "Client-API tetap mengembalikan HTTP ${API_WHILE_AUTH_DOWN_CODE} saat container auth-service berhenti." \
            "Sistem tetap melayani permintaan yang tidak bergantung pada komponen yang sedang dihentikan/di-restart."

        if [[ "$AUTH_DOWN_CODE" == "000" && "$API_WHILE_AUTH_DOWN_CODE" == "200" ]]; then
            assert_pass "Saat auth-service dihentikan, client-api tetap melayani GET /hazards (200 OK) secara independen!"
        else
            assert_fail "Gagal membuktikan independensi client-api saat auth-service mati: AuthCode=${AUTH_DOWN_CODE}, APICode=${API_WHILE_AUTH_DOWN_CODE}."
        fi
    fi

    # --------------------------------------------------------------------------
    # TEST P4.1b: Independensi Container — Stop/Restart aggregator Tanpa Merestart Container Lain
    # --------------------------------------------------------------------------
    assert_start "P4.1-AGG-RESTART" "Independensi Microservice: Stop & Start Ulang aggregator Tanpa Merestart Container Lain"

    if [[ "$NO_DOCKER" == "true" ]]; then
        assert_skip "Dilewati karena flag --no-docker aktif."
    else
        (cd "$PROJECT_ROOT" && docker compose stop aggregator > /dev/null 2>&1)

        # Saat aggregator berhenti:
        # 1. auth-service tetap harus bisa menerbitkan token (200 OK)
        AUTH_DURING_AGG_DOWN=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}" || true)
        # 2. client-api tidak crash, melainkan mengembalikan 503 UPSTREAM_UNAVAILABLE dan /health DEGRADED
        API_DURING_AGG_DOWN_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=2" || echo -e "\n000")
        API_DURING_AGG_DOWN_CODE=$(echo "$API_DURING_AGG_DOWN_RESP" | tail -n 1)
        API_DURING_AGG_DOWN_ERR=$(echo "$API_DURING_AGG_DOWN_RESP" | sed '$d' | jq -r '.error.code // ""')

        # Nyalakan kembali aggregator tanpa merestart client-api atau auth-service
        (cd "$PROJECT_ROOT" && docker compose start aggregator > /dev/null 2>&1)

        AGG_RECOVERED="false"
        for _ in {1..15}; do
            sleep 1
            CHECK_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OPS_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=2" || true)
            if [[ "$CHECK_CODE" == "200" ]]; then
                AGG_RECOVERED="true"
                break
            fi
        done

        print_interaction_details \
            "docker compose stop/start aggregator" "Auth (:8084) & Client-API (:8080)" \
            "Isolasi Kegagalan & Pemulihan Tanpa Restart Komponen Lain" "" \
            "WhileAggDown: AuthToken=${AUTH_DURING_AGG_DOWN}, ClientAPI=${API_DURING_AGG_DOWN_CODE} (${API_DURING_AGG_DOWN_ERR}) | AfterAggStart: Recovered=${AGG_RECOVERED}" \
            "Response Client-API saat Aggregator mati:\n$(echo "$API_DURING_AGG_DOWN_RESP" | sed '$d')" \
            "Saat aggregator mati, auth-service tetap 200 OK, client-api merespons 503 UPSTREAM_UNAVAILABLE secara terkontrol, dan langsung kembali 200 OK begitu aggregator dinyalakan ulang."

        if [[ "$AUTH_DURING_AGG_DOWN" == "200" && "$API_DURING_AGG_DOWN_CODE" == "503" && "$API_DURING_AGG_DOWN_ERR" == "UPSTREAM_UNAVAILABLE" && "$AGG_RECOVERED" == "true" ]]; then
            assert_pass "Independensi container terbukti: Auth tetap 200 OK, Client-API degradasi terkontrol (503 UPSTREAM_UNAVAILABLE) dan pulih otomatis ke 200 OK saat Aggregator menyala."
        else
            assert_fail "Uji restart independen aggregator gagal: Auth=${AUTH_DURING_AGG_DOWN}, API_Down=${API_DURING_AGG_DOWN_CODE}, Recovered=${AGG_RECOVERED}."
        fi
    fi
fi

# ==============================================================================
# BAGIAN 5: PROBLEM 5 — FAN-OUT EVENT DISTRIBUTION / PUB-SUB
# ==============================================================================
if should_run "p5"; then
    print_section "BAGIAN 5: PROBLEM 5 — FAN-OUT EVENT DISTRIBUTION / PUB-SUB"

    # --------------------------------------------------------------------------
    # TEST P5.1 & P5.2: Topologi Broker & Fan-Out ke >= 2 Consumer Independen
    # --------------------------------------------------------------------------
    assert_start "P5.1-P5.2" "Publikasi HazardEvent ke RabbitMQ Exchange 'hazard.events' & Fan-out ke >= 2 Consumer Independen"

    EX_INFO=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events" || echo "{}")
    EX_TYPE=$(echo "$EX_INFO" | jq -r '.type // ""')
    EX_DURABLE=$(echo "$EX_INFO" | jq -r '.durable // false')

    BINDINGS_INFO=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source" || echo "[]")
    HAS_DASH_Q=$(echo "$BINDINGS_INFO" | jq '[.[] | select(.destination == "dashboard")] | length' 2>/dev/null || echo "0")
    HAS_NOTIF_Q=$(echo "$BINDINGS_INFO" | jq '[.[] | select(.destination == "notifier")] | length' 2>/dev/null || echo "0")

    DASH_LOG_SAMPLE=""
    NOTIF_LOG_SAMPLE=""
    BOTH_RECEIVED="true"
    if [[ "$NO_DOCKER" == "false" ]]; then
        DASH_LOG_SAMPLE=$(cd "$PROJECT_ROOT" && docker compose logs --tail=30 consumer-dashboard 2>/dev/null | grep "hazard_event_received" | tail -n 2 || true)
        NOTIF_LOG_SAMPLE=$(cd "$PROJECT_ROOT" && docker compose logs --tail=30 consumer-notifier 2>/dev/null | grep "hazard_event_received" | tail -n 2 || true)
        if [[ -z "$DASH_LOG_SAMPLE" || -z "$NOTIF_LOG_SAMPLE" ]]; then
            BOTH_RECEIVED="false"
        fi
    fi

    print_interaction_details \
        "AMQP Topic Fan-out" "Exchange 'hazard.events' -> Queue 'dashboard' & 'notifier'" \
        "RabbitMQ Management API & Consumer Logs" "" \
        "ExchangeType=${EX_TYPE} (Durable=${EX_DURABLE}) | BoundDashboard=${HAS_DASH_Q} | BoundNotifier=${HAS_NOTIF_Q} | BothReceived=${BOTH_RECEIVED}" \
        "[Log consumer-dashboard]:\n${DASH_LOG_SAMPLE}\n\n[Log consumer-notifier]:\n${NOTIF_LOG_SAMPLE}" \
        "Exchange hazard.events bertipe topic & durable, serta minimal 2 consumer independen menerima event dengan message_id & correlation_id tanpa producer mengenali mereka."

    if [[ "$EX_TYPE" == "topic" && "$EX_DURABLE" == "true" && "$HAS_DASH_Q" -gt 0 && "$HAS_NOTIF_Q" -gt 0 && "$BOTH_RECEIVED" == "true" ]]; then
        assert_pass "Fan-out Pub/Sub berjalan baik: Exchange 'hazard.events' (topic, durable) menyalurkan event ke consumer-dashboard dan consumer-notifier."
    else
        assert_fail "Verifikasi topologi atau fan-out consumer gagal: Type=${EX_TYPE}, Durable=${EX_DURABLE}, Dash=${HAS_DASH_Q}, Notif=${HAS_NOTIF_Q}, Received=${BOTH_RECEIVED}."
    fi

    # --------------------------------------------------------------------------
    # TEST P5.3: Hentikan Satu Consumer -> Producer & Consumer Lain Jalan Normal -> Nyalakan Kembali (Catch-up)
    # --------------------------------------------------------------------------
    assert_start "P5.3" "Ketahanan Saat Satu Consumer Mati (consumer-notifier) & Penyusulan Event (Catch-up Durable Queue)"

    if [[ "$NO_DOCKER" == "true" ]]; then
        assert_skip "Dilewati karena flag --no-docker aktif."
    else
        echo -e "  ${YELLOW}ℹ Menghentikan consumer-notifier dan menunggu event baru terbit (11 detik)...${NC}"
        (cd "$PROJECT_ROOT" && docker compose stop consumer-notifier > /dev/null 2>&1)

        DASH_BEFORE_CNT=$(cd "$PROJECT_ROOT" && docker compose logs consumer-dashboard 2>/dev/null | grep -c "hazard_event_received" || echo "0")
        NOTIF_BEFORE_CNT=$(cd "$PROJECT_ROOT" && docker compose logs consumer-notifier 2>/dev/null | grep -c "hazard_event_received" || echo "0")

        # Tunggu generator mock menghasilkan event baru (~10 detik) + 1 siklus polling
        sleep 12

        # Cek jumlah pesan yang menumpuk (ready) di durable queue 'notifier' saat consumer-notifier mati
        Q_NOTIF_DURING=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier" || echo "{}")
        BACKLOG_MSGS=$(echo "$Q_NOTIF_DURING" | jq -r '.messages_ready // 0')
        DASH_DURING_CNT=$(cd "$PROJECT_ROOT" && docker compose logs consumer-dashboard 2>/dev/null | grep -c "hazard_event_received" || echo "0")
        AGG_STILL_UP=$(curl -s -o /dev/null -w "%{http_code}" "${AGGREGATOR_URL}/health" || true)

        # Nyalakan kembali consumer-notifier
        echo -e "  ${YELLOW}ℹ Menyalakan kembali consumer-notifier untuk menyusul (catch-up) pesan yang tertunda...${NC}"
        (cd "$PROJECT_ROOT" && docker compose start consumer-notifier > /dev/null 2>&1)

        NOTIF_AFTER_CNT="$NOTIF_BEFORE_CNT"
        for _ in {1..8}; do
            sleep 1
            NOTIF_AFTER_CNT=$(cd "$PROJECT_ROOT" && docker compose logs consumer-notifier 2>/dev/null | grep -c "hazard_event_received" || echo "0")
            if [[ "$NOTIF_AFTER_CNT" -gt "$NOTIF_BEFORE_CNT" ]]; then
                break
            fi
        done
        CATCHUP_SAMPLE=$(cd "$PROJECT_ROOT" && docker compose logs --tail=10 consumer-notifier 2>/dev/null | grep "hazard_event_received" | tail -n 3 || true)

        print_interaction_details \
            "docker compose stop/start consumer-notifier" "Queue 'notifier' & 'dashboard'" \
            "Durable Queue & Persistent Delivery (delivery_mode=2)" "" \
            "AggregatorHealth=${AGG_STILL_UP} | DashCount: ${DASH_BEFORE_CNT}->${DASH_DURING_CNT} | NotifierQueueBacklog=${BACKLOG_MSGS} | NotifCount: ${NOTIF_BEFORE_CNT}->${NOTIF_AFTER_CNT}" \
            "Log consumer-notifier setelah dinyalakan kembali (Catch-up):\n${CATCHUP_SAMPLE}" \
            "Saat consumer-notifier mati, aggregator & consumer-dashboard tetap berjalan normal, pesan disimpan di durable queue notifier, dan langsung tersusul (terkirim) saat consumer-notifier hidup kembali."

        if [[ "$AGG_STILL_UP" == "200" && "$DASH_DURING_CNT" -gt "$DASH_BEFORE_CNT" && "$NOTIF_AFTER_CNT" -gt "$NOTIF_BEFORE_CNT" ]]; then
            assert_pass "Catch-up berhasil! Saat consumer-notifier mati, consumer-dashboard tetap memproses event (${DASH_BEFORE_CNT}->${DASH_DURING_CNT}), dan setelah hidup kembali consumer-notifier menyusul seluruh pesan (${NOTIF_BEFORE_CNT}->${NOTIF_AFTER_CNT})."
        else
            assert_fail "Uji consumer mati & catch-up gagal: Agg=${AGG_STILL_UP}, Dash=${DASH_BEFORE_CNT}->${DASH_DURING_CNT}, Notif=${NOTIF_BEFORE_CNT}->${NOTIF_AFTER_CNT}."
        fi
    fi

    # --------------------------------------------------------------------------
    # TEST P5.4: Penambahan Consumer Baru (consumer-pemda-volcano) Tanpa Mengubah Kode Producer
    # --------------------------------------------------------------------------
    assert_start "P5.4" "Penambahan Consumer Baru (consumer-pemda-volcano) pada Exchange Tanpa Mengubah/Merestart Producer"

    if [[ "$NO_DOCKER" == "true" ]]; then
        assert_skip "Dilewati karena flag --no-docker aktif."
    else
        echo -e "  ${YELLOW}ℹ Menjalankan consumer ke-3: consumer-pemda-volcano (profile p5-extra, binding_key=volcanic)...${NC}"
        (cd "$PROJECT_ROOT" && docker compose --profile p5-extra up -d consumer-pemda-volcano > /dev/null 2>&1)

        # Tunggu queue pemda-volcano terikat dan event vulkanik baru terbit (~11 detik)
        sleep 12

        PEMDA_BINDING=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source" | \
            jq '[.[] | select(.destination == "pemda-volcano" and .routing_key == "volcanic")] | length' 2>/dev/null || echo "0")
        PEMDA_LOGS=$(cd "$PROJECT_ROOT" && docker compose --profile p5-extra logs --tail=20 consumer-pemda-volcano 2>/dev/null | grep "hazard_event_received" | tail -n 3 || true)

        if [[ "$SAVE_REPORT" == "true" ]]; then
            {
                echo "=== BUKTI P5.4 PENAMBAHAN CONSUMER BARU (consumer-pemda-volcano) ==="
                echo "$PEMDA_LOGS"
                echo ""
            } >> "$EVIDENCE_FILE"
        fi

        print_interaction_details \
            "docker compose --profile p5-extra up -d consumer-pemda-volcano" "Queue 'pemda-volcano' (binding_key='volcanic')" \
            "Tanpa mengubah kode atau me-restart service aggregator" "" \
            "BindingCount=${PEMDA_BINDING} | LogsReceived=$([[ -n "$PEMDA_LOGS" ]] && echo YES || echo NO)" \
            "Log consumer-pemda-volcano:\n${PEMDA_LOGS}" \
            "Consumer baru berhasil berlangganan ke exchange hazard.events dan menerima event VOLCANIC tanpa perubahan/restart pada Aggregator."

        if [[ "$PEMDA_BINDING" -gt 0 && -n "$PEMDA_LOGS" ]]; then
            assert_pass "Consumer baru 'consumer-pemda-volcano' berhasil terikat (routing_key=volcanic) dan menerima event secara real-time tanpa mengubah kode producer."
        else
            assert_fail "Consumer baru gagal menerima event: Binding=${PEMDA_BINDING}, Logs='${PEMDA_LOGS}'."
        fi

        # Bersihkan consumer ekstra setelah pengujian
        (cd "$PROJECT_ROOT" && docker compose --profile p5-extra stop consumer-pemda-volcano > /dev/null 2>&1 || true)
    fi
fi

# ==============================================================================
# RINGKASAN AKHIR
# ==============================================================================
echo -e "${CYAN}${BOLD}"
echo "================================================================================"
echo "                    RINGKASAN HASIL PENGUJIAN E2E MILESTONE 1                   "
echo "================================================================================"
echo -e "${NC}"
echo -e "Total Skenario Uji : ${BOLD}${TOTAL_TESTS}${NC}"
echo -e "Lolos (PASS)       : ${GREEN}${BOLD}${PASSED_TESTS}${NC}"
echo -e "Dilewati (SKIP)    : ${YELLOW}${BOLD}${SKIPPED_TESTS}${NC}"
echo -e "Gagal (FAIL)       : ${RED}${BOLD}${FAILED_TESTS}${NC}"

if [[ "$SAVE_REPORT" == "true" ]]; then
    echo -e "Laporan Lengkap    : ${CYAN}${REPORT_FILE}${NC}"
    if [[ -f "${EVIDENCE_FILE:-}" ]]; then
        echo -e "Potongan Bukti Log : ${CYAN}${EVIDENCE_FILE}${NC}"
    fi
fi
echo ""

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}🎉 SELAMAT! Seluruh skenario pengujian E2E Milestone 1 LULUS dengan sempurna!${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}⚠️  TERDAPAT ${FAILED_TESTS} PENGUJIAN YANG GAGAL:${NC}"
    for item in "${FAILED_LIST[@]}"; do
        echo -e "  ${RED}• ${item}${NC}"
    done
    echo ""
    exit 1
fi
