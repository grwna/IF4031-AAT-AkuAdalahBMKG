#!/usr/bin/env bash

# ==============================================================================
# Test Script: Service Aggregator, Auth Service & Client-Facing API - Milestone 1
# Spesifikasi: ctx-IF4031 - Tugas Besar - M1.md
# ==============================================================================

set -euo pipefail

# Konfigurasi Warna Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# Konfigurasi Endpoint & Token Default (dapat di-override via ENV atau CLI flags)
AGGREGATOR_URL="${AGGREGATOR_URL:-http://localhost:8083}"
BMKG_URL="${BMKG_URL:-http://localhost:8081}"
PVMBG_URL="${PVMBG_URL:-http://localhost:8082}"
CLIENT_API_URL="${CLIENT_API_URL:-http://localhost:8080}"
AUTH_URL="${AUTH_URL:-http://localhost:8084}"

PVMBG_TOKEN="${PVMBG_TOKEN:-$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PVMBG_BEARER_TOKEN" "")}"
BMKG_API_KEY="${BMKG_API_KEY:-$(read_env_var "${PROJECT_ROOT}/services/bmkg-mock/.env" "BMKG_API_KEY" "")}"

# Mode Detail Output (Default: true / Verbose)
SHOW_DETAILS="${SHOW_DETAILS:-true}"

# Kredensial Client Auth Service Default
CLIENT_MEDIA_ID="${CLIENT_MEDIA_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_ID" "media-client")}"
CLIENT_MEDIA_SECRET="${CLIENT_MEDIA_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_SECRET" "")}"

CLIENT_FIELD_ID="${CLIENT_FIELD_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_ID" "field-team")}"
CLIENT_FIELD_SECRET="${CLIENT_FIELD_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_SECRET" "")}"

CLIENT_OPS_ID="${CLIENT_OPS_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_ID" "bnpb-ops")}"
CLIENT_OPS_SECRET="${CLIENT_OPS_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_SECRET" "")}"

# Statistik Pengujian
PASSED_TESTS=0
FAILED_TESTS=0
TOTAL_TESTS=0

# Fungsi Bantuan Header & Usage
print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "======================================================================"
    echo "   M1 BNPB SYSTEM INTEGRATION TEST SUITE - AKU ADALAH BMKG          "
    echo "======================================================================"
    echo -e "${NC}"
    echo -e "Aggregator URL : ${YELLOW}${AGGREGATOR_URL}${NC}"
    echo -e "Client-API URL : ${YELLOW}${CLIENT_API_URL}${NC}"
    echo -e "Auth-Service URL: ${YELLOW}${AUTH_URL}${NC}"
    echo -e "BMKG Mock URL  : ${YELLOW}${BMKG_URL}${NC}"
    echo -e "PVMBG Mock URL : ${YELLOW}${PVMBG_URL}${NC}"
    echo -e "Verbose Mode   : ${YELLOW}${SHOW_DETAILS}${NC}"
    echo ""
}

usage() {
    cat <<EOF
Penggunaan: $(basename "$0") [PILIHAN]

Skrip pengujian otomatis untuk BNPB Distributed Gateway (Milestone 1).

Pilihan:
  -a, --aggregator URL   URL Service Aggregator (default: http://localhost:8083)
  -c, --client-api URL   URL Client-Facing API (default: http://localhost:8080)
  -s, --auth URL         URL Auth Service (default: http://localhost:8084)
  -b, --bmkg URL         URL Mock Service BMKG (default: http://localhost:8081)
  -p, --pvmbg URL        URL Mock Service PVMBG (default: http://localhost:8082)
  -t, --pvmbg-token TKN  Bearer Token PVMBG (default: pvmbg-secret-token-456)
  -k, --bmkg-key KEY     API Key BMKG (default: bmkg-secret-key-123)
  --compact              Sembunyikan rincian Request/Response/Expected (mode ringkas)
  -h, --help             Tampilkan bantuan ini

Contoh:
  $(basename "$0")
  $(basename "$0") -a http://localhost:8083 -c http://localhost:8080
EOF
    exit 0
}

# Parsing Argumen CLI
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--aggregator)
            AGGREGATOR_URL="$2"
            shift 2
            ;;
        -c|--client-api)
            CLIENT_API_URL="$2"
            shift 2
            ;;
        -s|--auth)
            AUTH_URL="$2"
            shift 2
            ;;
        -b|--bmkg)
            BMKG_URL="$2"
            shift 2
            ;;
        -p|--pvmbg)
            PVMBG_URL="$2"
            shift 2
            ;;
        -t|--pvmbg-token)
            PVMBG_TOKEN="$2"
            shift 2
            ;;
        -k|--bmkg-key)
            BMKG_API_KEY="$2"
            shift 2
            ;;
        --compact)
            SHOW_DETAILS="false"
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

# Pengecekan Dependensi (curl, jq)
check_dependencies() {
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}Error: Perintah '$cmd' tidak ditemukan. Harap install '$cmd' terlebih dahulu.${NC}"
            exit 1
        fi
    done
}

# Handler Cleanup (Trap) untuk mereset state PVMBG Mock saat skrip keluar/diinterupsi
cleanup() {
    echo ""
    echo -e "${YELLOW}▶ Menjalankan cleanup handler...${NC}"
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": false}' > /dev/null 2>&1 || true

    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"enabled": false}' > /dev/null 2>&1 || true

    echo -e "${GREEN}✓ Cleanup selesai.${NC}"
}
trap cleanup EXIT

# Assertion & Detail Printer Helpers
assert_start() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${BLUE}[TEST ${TOTAL_TESTS}]${NC} ${BOLD}${test_name}${NC}"
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
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ OUTGOING REQUEST                                                 │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${BOLD}Method & URL :${NC} ${BOLD}${method}${NC} ${url}"
        if [[ -n "$headers" ]]; then
            echo -e "    ${YELLOW}Headers      :${NC} ${headers}"
        fi
        if [[ -n "$req_body" ]] && [[ "$req_body" != "null" ]]; then
            echo -e "    ${YELLOW}Request Body :${NC} $(echo "$req_body" | jq -c . 2>/dev/null || echo "$req_body")"
        fi
        echo ""
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ RECEIVED RESPONSE                                                │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${YELLOW}Status Code  :${NC} ${resp_code}"
        if [[ -n "$resp_body" ]]; then
            echo -e "    ${YELLOW}Response Body:${NC}"
            echo "$resp_body" | jq . 2>/dev/null | sed 's/^/      /' || echo "      $resp_body"
        fi
        echo ""
        echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│ EXPECTED ASSERTION                                               │${NC}"
        echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────┘${NC}"
        echo -e "    ${BOLD}${expected_desc}${NC}"
        echo -e "  ${CYAN}└──────────────────────────────────────────────────────────────────┘${NC}"
    fi
}

assert_pass() {
    local message="$1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✓ PASS:${NC} ${message}"
    echo ""
}

assert_fail() {
    local message="$1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✗ FAIL:${NC} ${message}"
    echo ""
}

# ==============================================================================
# EKSEKUSI PENGUJIAN
# ==============================================================================

check_dependencies
print_banner

# ------------------------------------------------------------------------------
# TEST 1: Health Check & Source Status Service Aggregator
# ------------------------------------------------------------------------------
assert_start "P1/P4: Health Check & Source Status API (Aggregator)"

HEALTH_RESP=$(curl -s -w "\n%{http_code}" "${AGGREGATOR_URL}/health" || echo -e "\n000")
HEALTH_CODE=$(echo "$HEALTH_RESP" | tail -n 1)
HEALTH_BODY=$(echo "$HEALTH_RESP" | sed '$d')

STATUS_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: test-health-123" "${AGGREGATOR_URL}/internal/source-status" || echo -e "\n000")
STATUS_CODE=$(echo "$STATUS_RESP" | tail -n 1)
STATUS_BODY=$(echo "$STATUS_RESP" | sed '$d')

print_interaction_details \
    "GET" "${AGGREGATOR_URL}/health & /internal/source-status" \
    "X-Correlation-ID: test-health-123" "" \
    "Health=${HEALTH_CODE}, Status=${STATUS_CODE}" \
    "HealthBody: ${HEALTH_BODY}\nStatusBody: ${STATUS_BODY}" \
    "HTTP 200 OK pada /health (status: UP) dan /internal/source-status mengembalikan status BMKG & PVMBG."

if [[ "$HEALTH_CODE" == "200" ]] && echo "$HEALTH_BODY" | jq -e '.status == "UP"' > /dev/null 2>&1; then
    if echo "$STATUS_BODY" | jq -e '.source_status.BMKG != null and .source_status.PVMBG != null' > /dev/null 2>&1; then
        assert_pass "Service Aggregator UP & endpoint /internal/source-status merespons dengan status BMKG & PVMBG."
    else
        assert_fail "Endpoint /internal/source-status tidak mengembalikan status BMKG/PVMBG yang valid."
    fi
else
    assert_fail "Aggregator Health Check gagal. Status Code: ${HEALTH_CODE}, Body: ${HEALTH_BODY}"
fi

# ------------------------------------------------------------------------------
# TEST 2: Problem 1 - Dynamic Schema Evolution (PVMBG confidence_level)
# ------------------------------------------------------------------------------
assert_start "P1: Dynamic Schema Evolution (PVMBG confidence_level)"

# Step 2a: Aktifkan confidence_level pada PVMBG Mock
SCHEMA_TRIGGER=$(curl -s -w "\n%{http_code}" -X POST "${PVMBG_URL}/admin/schema-version" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PVMBG_TOKEN}" \
    -d '{"enabled": true}' || echo -e "\n000")
SCHEMA_CODE=$(echo "$SCHEMA_TRIGGER" | tail -n 1)
SCHEMA_BODY=$(echo "$SCHEMA_TRIGGER" | sed '$d')

if [[ "$SCHEMA_CODE" != "200" ]]; then
    print_interaction_details "POST" "${PVMBG_URL}/admin/schema-version" "Authorization: Bearer ${PVMBG_TOKEN}" '{"enabled": true}' "$SCHEMA_CODE" "$SCHEMA_BODY" "HTTP 200 OK (schema-version enabled: true)"
    assert_fail "Gagal memicu perubahan skema pada PVMBG Mock. Code: ${SCHEMA_CODE}"
else
    echo -e "  ${YELLOW}ℹ Pemicu perubahan skema dikirim ke PVMBG Mock. Menunggu polling interval (4 detik)...${NC}"
    sleep 4

    # Step 2b: Ambil hazards vulkanik dari Aggregator
    HAZARDS_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: test-p1-schema" "${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC&limit=20" || echo -e "\n000")
    HAZARDS_CODE=$(echo "$HAZARDS_RESP" | tail -n 1)
    HAZARDS_BODY=$(echo "$HAZARDS_RESP" | sed '$d')

    print_interaction_details \
        "POST -> GET" "${PVMBG_URL}/admin/schema-version -> ${AGGREGATOR_URL}/internal/hazards?type=VOLCANIC&limit=20" \
        "Authorization: Bearer ${PVMBG_TOKEN} | X-Correlation-ID: test-p1-schema" \
        '{"enabled": true}' \
        "SchemaCode=${SCHEMA_CODE}, HazardsCode=${HAZARDS_CODE}" \
        "SchemaBody: ${SCHEMA_BODY}\n\nHazardsBody (Sample Output): $(echo "$HAZARDS_BODY" | jq '.data[0..2]' 2>/dev/null || echo "$HAZARDS_BODY")" \
        "PVMBG mengembalikan confidence_level, dan Aggregator memasukkannya secara dinamis ke attributes tanpa restart."

    HAS_CONFIDENCE=$(echo "$HAZARDS_BODY" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")

    if [[ "$HAS_CONFIDENCE" -gt 0 ]]; then
        CONF_VAL=$(echo "$HAZARDS_BODY" | jq -r '[.data[] | select(.attributes.confidence_level != null)][0].attributes.confidence_level')
        assert_pass "Aggregator berhasil memuat field baru 'confidence_level' (Nilai contoh: ${CONF_VAL}) ke dalam 'attributes' tanpa crash atau restart."
    else
        assert_fail "Field 'confidence_level' tidak ditemukan di attributes hazard vulkanik setelah skema dipicu."
    fi

    # Reset schema version
    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"enabled": false}' > /dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# TEST 3: Problem 2 - Head-of-Line Blocking & BMKG Latency (< 300 ms p95)
# ------------------------------------------------------------------------------
assert_start "P2: Isolation Read Path & Head-of-Line Blocking (Latensi SEISMIC < 300ms p95)"

LATENCY_SAMPLES=10
LATENCIES=()
FAILED_LATENCY_REQ=0

echo -e "  ${YELLOW}ℹ Mengirim ${LATENCY_SAMPLES} permintaan paralel/beruntun untuk data SEISMIC...${NC}"
for ((i=1; i<=LATENCY_SAMPLES; i++)); do
    START_TIME=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s%3N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Correlation-ID: test-p2-latency-$i" "${AGGREGATOR_URL}/internal/hazards?type=SEISMIC&limit=10" || echo "000")
    END_TIME=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s%3N)
    
    DURATION=$((END_TIME - START_TIME))
    if [[ "$HTTP_CODE" == "200" ]]; then
        LATENCIES+=("$DURATION")
    else
        FAILED_LATENCY_REQ=$((FAILED_LATENCY_REQ + 1))
    fi
done

if [[ "${#LATENCIES[@]}" -gt 0 ]]; then
    SORTED_LATENCIES=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
    P95_INDEX=$(( (${#SORTED_LATENCIES[@]} * 95 / 100) - 1 ))
    [[ $P95_INDEX -lt 0 ]] && P95_INDEX=0
    LAST_INDEX=$(( ${#SORTED_LATENCIES[@]} - 1 ))
    [[ $LAST_INDEX -lt 0 ]] && LAST_INDEX=0

    P95_LATENCY="${SORTED_LATENCIES[$P95_INDEX]}"
    MIN_LATENCY="${SORTED_LATENCIES[0]}"
    MAX_LATENCY="${SORTED_LATENCIES[$LAST_INDEX]}"

    print_interaction_details \
        "GET" "${AGGREGATOR_URL}/internal/hazards?type=SEISMIC&limit=10 (x${LATENCY_SAMPLES})" \
        "X-Correlation-ID: test-p2-latency-1..10" "" \
        "HTTP 200 OK (Semua ${#LATENCIES[@]} request)" \
        "Latensi: Min=${MIN_LATENCY}ms, Max=${MAX_LATENCY}ms, p95=${P95_LATENCY}ms" \
        "HTTP 200 OK dan p95 latensi < 300 ms (Bebas dari Head-of-Line Blocking)."

    if [[ "$P95_LATENCY" -lt 300 ]] && [[ "$FAILED_LATENCY_REQ" -eq 0 ]]; then
        assert_pass "p95 latensi permintaan SEISMIC adalah ${P95_LATENCY}ms (< 300 ms) - Bebas dari Head-of-Line blocking."
    else
        assert_fail "p95 latensi SEISMIC (${P95_LATENCY}ms) melebihi batas 300 ms atau terdapat request gagal (${FAILED_LATENCY_REQ})."
    fi
else
    assert_fail "Seluruh permintaan latensi SEISMIC gagal dikirim ke Aggregator."
fi

# ------------------------------------------------------------------------------
# TEST 4: Problem 2 - Outage & Graceful Degradation (PVMBG Outage Handling)
# ------------------------------------------------------------------------------
assert_start "P2: Outage & Graceful Degradation (PVMBG Outage)"

# Step 4a: Nyalakan Outage PVMBG
OUTAGE_TRIGGER=$(curl -s -w "\n%{http_code}" -X POST "${PVMBG_URL}/admin/outage" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PVMBG_TOKEN}" \
    -d '{"outage": true}' || echo -e "\n000")
OUTAGE_CODE=$(echo "$OUTAGE_TRIGGER" | tail -n 1)
OUTAGE_BODY=$(echo "$OUTAGE_TRIGGER" | sed '$d')

if [[ "$OUTAGE_CODE" != "200" ]]; then
    print_interaction_details "POST" "${PVMBG_URL}/admin/outage" "Authorization: Bearer ${PVMBG_TOKEN}" '{"outage": true}' "$OUTAGE_CODE" "$OUTAGE_BODY" "HTTP 200 OK (outage enabled)"
    assert_fail "Gagal memicu mode outage pada PVMBG Mock. Code: ${OUTAGE_CODE}"
else
    echo -e "  ${YELLOW}ℹ Mode Outage PVMBG diaktifkan. Menunggu poller memperbarui status (4 detik)...${NC}"
    sleep 4

    # Step 4b: Minta data dari Aggregator saat PVMBG outage
    OUTAGE_HAZARDS_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: test-p2-outage" "${AGGREGATOR_URL}/internal/hazards" || echo -e "\n000")
    OUTAGE_HAZARDS_CODE=$(echo "$OUTAGE_HAZARDS_RESP" | tail -n 1)
    OUTAGE_HAZARDS_BODY=$(echo "$OUTAGE_HAZARDS_RESP" | sed '$d')

    PVMBG_STATUS=$(echo "$OUTAGE_HAZARDS_BODY" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
    STALE_SINCE=$(echo "$OUTAGE_HAZARDS_BODY" | jq -r '.source_status.PVMBG.stale_since // "null"')
    VOLCANIC_COUNT=$(echo "$OUTAGE_HAZARDS_BODY" | jq '[.data[] | select(.source == "PVMBG")] | length')

    print_interaction_details \
        "POST -> GET" "${PVMBG_URL}/admin/outage -> ${AGGREGATOR_URL}/internal/hazards" \
        "Authorization: Bearer ${PVMBG_TOKEN} | X-Correlation-ID: test-p2-outage" \
        '{"outage": true}' \
        "OutageTrigger=${OUTAGE_CODE}, HazardsResp=${OUTAGE_HAZARDS_CODE}" \
        "SourceStatus: $(echo "$OUTAGE_HAZARDS_BODY" | jq '.source_status' 2>/dev/null || echo "N/A")" \
        "Aggregator tetap merespons 200 OK saat PVMBG outage, status PVMBG = DEGRADED, stale_since terisi, & data vulkanik terakhir disajikan dari Canonical Store."

    if [[ "$OUTAGE_HAZARDS_CODE" == "200" ]] && [[ "$PVMBG_STATUS" == "DEGRADED" ]]; then
        assert_pass "Aggregator tetap merespons 200 OK saat PVMBG outage. Status PVMBG: DEGRADED, stale_since: ${STALE_SINCE}, Data vulkanik terakhir disajikan dari Canonical Store (Total: ${VOLCANIC_COUNT})."
    else
        assert_fail "Respons saat PVMBG outage tidak sesuai spec. HTTP Code: ${OUTAGE_HAZARDS_CODE}, Status PVMBG: ${PVMBG_STATUS}"
    fi

    # Step 4c: Matikan Mode Outage dan verifikasi Recovery ke status UP
    echo -e "  ${YELLOW}ℹ Mematikan mode Outage PVMBG. Menunggu recovery status (maksimal 8 detik)...${NC}"
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": false}' > /dev/null 2>&1 || true

    RECOVERED_STATUS="UNKNOWN"
    for ((attempt=1; attempt<=8; attempt++)); do
        sleep 1
        RECOVERY_RESP=$(curl -s -H "X-Correlation-ID: test-p2-recovery-$attempt" "${AGGREGATOR_URL}/internal/source-status" || echo "")
        RECOVERED_STATUS=$(echo "$RECOVERY_RESP" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
        if [[ "$RECOVERED_STATUS" == "UP" ]]; then
            break
        fi
    done

    if [[ "$RECOVERED_STATUS" == "UP" ]]; then
        assert_pass "Sistem kembali ke status UP secara otomatis tanpa perlu merestart service Aggregator."
    else
        assert_fail "Status PVMBG gagal me-recover ke UP setelah outage dimatikan. Status saat ini: ${RECOVERED_STATUS}"
    fi
fi

# ------------------------------------------------------------------------------
# TEST 5: Problem 4 - Internal API Contract & Canonical Hazard Event Validation
# ------------------------------------------------------------------------------
assert_start "P4: Validasi Kontrak API Internal & Format HazardEvent Kanonik"

CONTRACT_RESP=$(curl -s -w "\n%{http_code}" -H "X-Correlation-ID: test-p4-contract" "${AGGREGATOR_URL}/internal/hazards?limit=5" || echo -e "\n000")
CONTRACT_CODE=$(echo "$CONTRACT_RESP" | tail -n 1)
CONTRACT_BODY=$(echo "$CONTRACT_RESP" | sed '$d')

VALID_FIELDS=$(echo "$CONTRACT_BODY" | jq -r '.data[0] | select(.hazard_id != null and .source != null and .source_ref_id != null and .hazard_type != null and .severity != null and .area_name != null and .occurred_at != null and .ingested_at != null and .attributes != null) | .hazard_id')

print_interaction_details \
    "GET" "${AGGREGATOR_URL}/internal/hazards?limit=5" \
    "X-Correlation-ID: test-p4-contract" "" \
    "Status Code: ${CONTRACT_CODE}" \
    "Sample Item: $(echo "$CONTRACT_BODY" | jq '.data[0]' 2>/dev/null || echo "$CONTRACT_BODY")" \
    "Format HazardEvent Kanonik memuat hazard_id unik (<SOURCE>-<ref_id>), seluruh field kanonik, & next_cursor valid."

if [[ -n "$VALID_FIELDS" ]] && [[ "$VALID_FIELDS" != "null" ]]; then
    if [[ "$VALID_FIELDS" =~ ^(BMKG|PVMBG)-.+ ]]; then
        NEXT_CURSOR=$(echo "$CONTRACT_BODY" | jq -r '.next_cursor // ""')
        if [[ -n "$NEXT_CURSOR" ]] && [[ "$NEXT_CURSOR" != "null" ]]; then
            PAGED_RESP=$(curl -s -H "X-Correlation-ID: test-p4-cursor" "${AGGREGATOR_URL}/internal/hazards?limit=5&cursor=${NEXT_CURSOR}" || echo "")
            PAGED_COUNT=$(echo "$PAGED_RESP" | jq '.data | length')
            if [[ "$PAGED_COUNT" -gt 0 ]]; then
                assert_pass "Format HazardEvent Kanonik valid (ID: ${VALID_FIELDS}) dan pagination berbasis 'next_cursor' bekerja dengan benar."
            else
                assert_fail "Pagination menggunakan 'cursor' mengembalikan data kosong."
            fi
        else
            assert_pass "Format HazardEvent Kanonik valid (ID: ${VALID_FIELDS})."
        fi
    else
        assert_fail "Format hazard_id ('${VALID_FIELDS}') tidak memenuhi standar <SOURCE>-<source_ref_id>."
    fi
else
    assert_fail "Struktur HazardEvent Kanonik dari /internal/hazards tidak lengkap atau tidak valid."
fi

# ------------------------------------------------------------------------------
# TEST 6: Problem 3 - Auth Service Token Issuance (POST /token)
# ------------------------------------------------------------------------------
assert_start "P3: Auth Service - Issue Token untuk Scope Berbeda (POST /token)"

MEDIA_REQ_BODY="{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"${CLIENT_MEDIA_SECRET}\"}"
MEDIA_TOKEN_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/token" \
    -H "Content-Type: application/json" \
    -d "$MEDIA_REQ_BODY" || echo -e "\n000")
MEDIA_TOKEN_CODE=$(echo "$MEDIA_TOKEN_RESP" | tail -n 1)
MEDIA_TOKEN_BODY=$(echo "$MEDIA_TOKEN_RESP" | sed '$d')

MEDIA_ACCESS_TOKEN=$(echo "$MEDIA_TOKEN_BODY" | jq -r '.access_token // ""')
MEDIA_SCOPE=$(echo "$MEDIA_TOKEN_BODY" | jq -r '.scope // ""')

FIELD_REQ_BODY="{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"${CLIENT_FIELD_SECRET}\"}"
FIELD_TOKEN_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/token" \
    -H "Content-Type: application/json" \
    -d "$FIELD_REQ_BODY" || echo -e "\n000")
FIELD_TOKEN_CODE=$(echo "$FIELD_TOKEN_RESP" | tail -n 1)
FIELD_TOKEN_BODY=$(echo "$FIELD_TOKEN_RESP" | sed '$d')

FIELD_ACCESS_TOKEN=$(echo "$FIELD_TOKEN_BODY" | jq -r '.access_token // ""')
FIELD_REFRESH_TOKEN=$(echo "$FIELD_TOKEN_BODY" | jq -r '.refresh_token // ""')
FIELD_SCOPE=$(echo "$FIELD_TOKEN_BODY" | jq -r '.scope // ""')

print_interaction_details \
    "POST" "${AUTH_URL}/token" \
    "Content-Type: application/json" \
    "Media: ${CLIENT_MEDIA_ID} | Field: ${CLIENT_FIELD_ID}" \
    "MediaCode=${MEDIA_TOKEN_CODE}, FieldCode=${FIELD_TOKEN_CODE}" \
    "MediaBody: ${MEDIA_TOKEN_BODY}\n\nFieldBody: ${FIELD_TOKEN_BODY}" \
    "HTTP 200 OK. Media Scope = 'hazards:read:summary', Field Team Scope = 'hazards:read:raw' (beserta refresh_token)."

if [[ "$MEDIA_TOKEN_CODE" == "200" ]] && [[ "$MEDIA_SCOPE" == "hazards:read:summary" ]] && \
   [[ "$FIELD_TOKEN_CODE" == "200" ]] && [[ "$FIELD_SCOPE" == "hazards:read:raw" ]] && [[ -n "$FIELD_REFRESH_TOKEN" ]]; then
    assert_pass "Token berhasil diterbitkan oleh Auth Service. Media Scope: '${MEDIA_SCOPE}', Field Team Scope: '${FIELD_SCOPE}'."
else
    assert_fail "Gagal menerbitkan token dari Auth Service. Media Code: ${MEDIA_TOKEN_CODE}, Field Code: ${FIELD_TOKEN_CODE}"
fi

# ------------------------------------------------------------------------------
# TEST 7: Problem 3 - Auth Service Refresh Token Flow (POST /refresh)
# ------------------------------------------------------------------------------
assert_start "P3: Auth Service - Refresh Token Flow (POST /refresh)"

if [[ -n "$FIELD_REFRESH_TOKEN" ]]; then
    REFRESH_REQ_BODY="{\"refresh_token\":\"${FIELD_REFRESH_TOKEN}\"}"
    REFRESH_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/refresh" \
        -H "Content-Type: application/json" \
        -d "$REFRESH_REQ_BODY" || echo -e "\n000")
    REFRESH_CODE=$(echo "$REFRESH_RESP" | tail -n 1)
    REFRESH_BODY=$(echo "$REFRESH_RESP" | sed '$d')

    NEW_ACCESS_TOKEN=$(echo "$REFRESH_BODY" | jq -r '.access_token // ""')
    NEW_REFRESH_TOKEN=$(echo "$REFRESH_BODY" | jq -r '.refresh_token // ""')

    # Cek apakah refresh_token lama ditolak setelah digunakan (Single-Use Rotation)
    REUSE_RESP=$(curl -s -w "\n%{http_code}" -X POST "${AUTH_URL}/refresh" \
        -H "Content-Type: application/json" \
        -d "$REFRESH_REQ_BODY" || echo -e "\n000")
    REUSE_CODE=$(echo "$REUSE_RESP" | tail -n 1)
    REUSE_BODY=$(echo "$REUSE_RESP" | sed '$d')

    print_interaction_details \
        "POST" "${AUTH_URL}/refresh" \
        "Content-Type: application/json" \
        "$REFRESH_REQ_BODY" \
        "RefreshCode=${REFRESH_CODE}, ReuseCode=${REUSE_CODE}" \
        "RefreshBody: ${REFRESH_BODY}\n\nReuseBody: ${REUSE_BODY}" \
        "HTTP 200 OK pada pembaruan token pertama & HTTP 401 Unauthorized saat refresh_token lama digunakan ulang."

    if [[ "$REFRESH_CODE" == "200" ]] && [[ -n "$NEW_ACCESS_TOKEN" ]] && [[ "$REUSE_CODE" == "401" ]]; then
        assert_pass "Alur Refresh Token sukses mendapatkan access token baru dan membatalkan refresh_token lama (Status Re-use: 401)."
    else
        assert_fail "Refresh Token flow gagal atau refresh token lama tidak dibatalkan. Refresh Code: ${REFRESH_CODE}, Reuse Code: ${REUSE_CODE}"
    fi
else
    assert_fail "Pengujian Refresh Token dilewati karena refresh_token awal tidak didapatkan."
fi

# ------------------------------------------------------------------------------
# TEST 8: Problem 3 - Client-Facing API Media Scope Enforcement
# ------------------------------------------------------------------------------
assert_start "P3: Client-Facing API - Media Scope Enforcement (Ringkasan Saja)"

# 8a: Panggilan tanpa Token (Wajib 401)
UNAUTH_RESP=$(curl -s -w "\n%{http_code}" "${CLIENT_API_URL}/hazards" || echo -e "\n000")
UNAUTH_CODE=$(echo "$UNAUTH_RESP" | tail -n 1)
UNAUTH_BODY=$(echo "$UNAUTH_RESP" | sed '$d')

# 8b: Panggilan dengan Media Token (Wajib 200, Ringkasan Saja)
if [[ -n "$MEDIA_ACCESS_TOKEN" ]]; then
    MEDIA_API_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5" || echo -e "\n000")
    MEDIA_API_CODE=$(echo "$MEDIA_API_RESP" | tail -n 1)
    MEDIA_API_BODY=$(echo "$MEDIA_API_RESP" | sed '$d')

    LEAKED_ATTRIBUTES=$(echo "$MEDIA_API_BODY" | jq '[.data[] | select(.attributes != null or .latitude != null or .longitude != null or .source_ref_id != null)] | length' 2>/dev/null || echo "0")

    # 8c: Permintaan eksplisit ke endpoint raw dengan Media Token (Wajib 403 Forbidden)
    RAW_DENIED_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${MEDIA_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards/BMKG-bmkg-0001/raw" || echo -e "\n000")
    RAW_DENIED_CODE=$(echo "$RAW_DENIED_RESP" | tail -n 1)
    RAW_DENIED_BODY=$(echo "$RAW_DENIED_RESP" | sed '$d')

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards" \
        "Authorization: Bearer ${MEDIA_ACCESS_TOKEN:0:15}..." "" \
        "UnauthCode=${UNAUTH_CODE}, MediaCode=${MEDIA_API_CODE}, RawDeniedCode=${RAW_DENIED_CODE}" \
        "MediaResponseSample: $(echo "$MEDIA_API_BODY" | jq '.data[0]' 2>/dev/null || echo "$MEDIA_API_BODY")" \
        "HTTP 401 saat tanpa token, HTTP 200 dengan Media Token (0 field mentah terbocor), dan HTTP 403 saat meminta endpoint /raw."

    if [[ "$UNAUTH_CODE" == "401" ]] && [[ "$MEDIA_API_CODE" == "200" ]] && [[ "$LEAKED_ATTRIBUTES" -eq 0 ]] && [[ "$RAW_DENIED_CODE" == "403" ]]; then
        assert_pass "Penegakan Hak Akses Media LULUS: Tanpa token (401), Media Token (200, Hanya Ringkasan, 0 Field Mentah), Permintaan Raw (403 Forbidden)."
    else
        assert_fail "Pelanggaran Scope Media! Unauth Code: ${UNAUTH_CODE}, Media Code: ${MEDIA_API_CODE}, Leaked Raw Fields: ${LEAKED_ATTRIBUTES}, Raw Access Code: ${RAW_DENIED_CODE}"
    fi
else
    assert_fail "Pengujian Scope Media dilewati karena Media Access Token tidak didapatkan."
fi

# ------------------------------------------------------------------------------
# TEST 9: Problem 3 - Client-Facing API Field Team/Ops Access & Refreshed Token
# ------------------------------------------------------------------------------
assert_start "P3: Client-Facing API - Field Team / Ops Access & Refreshed Token"

if [[ -n "$FIELD_ACCESS_TOKEN" ]]; then
    FIELD_API_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${FIELD_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5" || echo -e "\n000")
    FIELD_API_CODE=$(echo "$FIELD_API_RESP" | tail -n 1)
    FIELD_API_BODY=$(echo "$FIELD_API_RESP" | sed '$d')

    HAS_RAW_FIELDS=$(echo "$FIELD_API_BODY" | jq '[.data[] | select(.attributes != null or .source_ref_id != null)] | length' 2>/dev/null || echo "0")

    # Gunakan Token Hasil Refresh
    REFRESHED_API_CODE="000"
    REFRESHED_API_BODY=""
    if [[ -n "${NEW_ACCESS_TOKEN:-}" ]]; then
        REFRESHED_API_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${NEW_ACCESS_TOKEN}" "${CLIENT_API_URL}/hazards?limit=5" || echo -e "\n000")
        REFRESHED_API_CODE=$(echo "$REFRESHED_API_RESP" | tail -n 1)
        REFRESHED_API_BODY=$(echo "$REFRESHED_API_RESP" | sed '$d')
    fi

    print_interaction_details \
        "GET" "${CLIENT_API_URL}/hazards" \
        "Authorization: Bearer ${FIELD_ACCESS_TOKEN:0:15}..." "" \
        "FieldCode=${FIELD_API_CODE}, RefreshedTokenCode=${REFRESHED_API_CODE}" \
        "FieldResponseSample: $(echo "$FIELD_API_BODY" | jq '.data[0]' 2>/dev/null || echo "$FIELD_API_BODY")" \
        "HTTP 200 OK untuk Field Team / Ops (data mentah & attributes terisi) serta Token hasil Refresh dapat digunakan dengan normal."

    if [[ "$FIELD_API_CODE" == "200" ]] && [[ "$HAS_RAW_FIELDS" -gt 0 ]] && [[ "$REFRESHED_API_CODE" == "200" ]]; then
        assert_pass "Akses Field Team / Ops LULUS: Menerima data mentah (attributes & source_ref_id) dan Token hasil Refresh berfungsi dengan baik (200 OK)."
    else
        assert_fail "Akses Field Team / Ops gagal. Code: ${FIELD_API_CODE}, Raw Fields Count: ${HAS_RAW_FIELDS}, Refreshed Token Code: ${REFRESHED_API_CODE}"
    fi
else
    assert_fail "Pengujian Field Team dilewati karena Field Access Token tidak didapatkan."
fi

# ==============================================================================
# RINGKASAN HASIL PENGUJIANKU
# ==============================================================================
echo -e "${CYAN}${BOLD}"
echo "======================================================================"
echo "                         HASIL PENGUJIAN                              "
echo "======================================================================"
echo -e "${NC}"
echo -e "Total Pengujian  : ${BOLD}${TOTAL_TESTS}${NC}"
echo -e "Lolos (PASS)     : ${GREEN}${BOLD}${PASSED_TESTS}${NC}"
echo -e "Gagal (FAIL)     : ${RED}${BOLD}${FAILED_TESTS}${NC}"
echo ""

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}🎉 SELAMAT! Seluruh pengujian BNPB Gateway LULUS dengan sempurna!${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}⚠️  TERDAPAT ${FAILED_TESTS} PENGUJIAN YANG GAGAL. Periksa log di atas.${NC}"
    echo ""
    exit 1
fi
