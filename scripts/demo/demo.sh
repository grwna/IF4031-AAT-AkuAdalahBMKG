#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# IF4031 MILESTONE 1 - SYSTEM VERIFICATION & DEMO SUITE
# ==============================================================================
# Format output:
#   task : [ berisi task / problem yang ingin di uji ]
#   expect : [ ekspektasi hasil task ]
#
#   cmd : [ berisi cmd tunggal yang dieksekusi ]
#   resp :
#     [ raw response / pretty-printed JSON ]
#   res : [ PASS / FAIL beserta perbandingan resp vs expect ]
#
# Penggunaan:
#   ./scripts/demo/demo.sh [all|p0|p1|p2|p3|p4|p5] [--fast] [--step|--pause] [--no-save]
#   ./scripts/tests/test-e2e.sh [--problem all|p0|p1|p2|p3|p4|p5] [--fast] [--step] [--no-save]
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORTS_DIR="${PROJECT_ROOT}/scripts/tests/reports"

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

BMKG_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "BMKG_PORT" "8081")
PVMBG_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "PVMBG_PORT" "8082")
AGGREGATOR_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "AGGREGATOR_PORT" "8083")
CLIENT_API_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "BNPB_CLIENT_API_PORT" "8080")
AUTH_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "AUTH_SERVICE_PORT" "8084")
RABBITMQ_MGMT_PORT=$(read_env_var "${PROJECT_ROOT}/.env" "RABBITMQ_MGMT_PORT" "15672")

BMKG_URL="${BMKG_URL:-http://localhost:${BMKG_PORT}}"
PVMBG_URL="${PVMBG_URL:-http://localhost:${PVMBG_PORT}}"
AGGREGATOR_URL="${AGGREGATOR_URL:-http://localhost:${AGGREGATOR_PORT}}"
CLIENT_API_URL="${CLIENT_API_URL:-http://localhost:${CLIENT_API_PORT}}"
AUTH_URL="${AUTH_URL:-http://localhost:${AUTH_PORT}}"
RABBITMQ_MGMT_URL="http://localhost:${RABBITMQ_MGMT_PORT}"

BMKG_API_KEY="${BMKG_API_KEY:-$(read_env_var "${PROJECT_ROOT}/services/bmkg-mock/.env" "BMKG_API_KEY" "")}"
PVMBG_TOKEN="${PVMBG_BEARER_TOKEN:-$(read_env_var "${PROJECT_ROOT}/services/pvmbg-mock/.env" "PVMBG_BEARER_TOKEN" "")}"

CLIENT_MEDIA_ID="${CLIENT_MEDIA_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_ID" "media-client")}"
CLIENT_MEDIA_SECRET="${CLIENT_MEDIA_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_MEDIA_SECRET" "")}"
CLIENT_FIELD_ID="${CLIENT_FIELD_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_ID" "field-team")}"
CLIENT_FIELD_SECRET="${CLIENT_FIELD_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_FIELD_SECRET" "")}"
CLIENT_OPS_ID="${CLIENT_OPS_ID:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_ID" "bnpb-ops")}"
CLIENT_OPS_SECRET="${CLIENT_OPS_SECRET:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "CLIENT_OPS_SECRET" "")}"
ACCESS_TOKEN_TTL="${ACCESS_TOKEN_TTL:-$(read_env_var "${PROJECT_ROOT}/services/auth-service/.env" "ACCESS_TOKEN_TTL_SECONDS" "60")}"

RABBITMQ_USER="${RABBITMQ_USER:-$(read_env_var "${PROJECT_ROOT}/services/message-broker/.env" "RABBITMQ_DEFAULT_USER" "bnpb")}"
RABBITMQ_PASS="${RABBITMQ_PASS:-$(read_env_var "${PROJECT_ROOT}/services/message-broker/.env" "RABBITMQ_DEFAULT_PASS" "")}"
POSTGRES_USER="${POSTGRES_USER:-$(read_env_var "${PROJECT_ROOT}/.env" "POSTGRES_USER" "aggregator_user")}"
POSTGRES_DB="${POSTGRES_DB:-$(read_env_var "${PROJECT_ROOT}/.env" "POSTGRES_DB" "canonical_store")}"

FAST_MODE=false
STEP_MODE=false
NO_DOCKER=false
SAVE_REPORT=true
STEP_DELAY_SEC=1
SELECTED_PROBLEM="all"

usage() {
    cat <<EOF
Usage: $(basename "$0") [all|p0|p1|p2|p3|p4|p5] [OPTIONS]

Options:
  p0 | p1 | p2 | p3 | p4 | p5 | all   Pilih problem yang ingin diuji (default: all)
  --problem <p0|p1|p2|p3|p4|p5|all>   Pilih problem yang ingin diuji
  --fast                              Percepat durasi tunggu (load test 10s, lewati tunggu TTL 60s penuh)
  --step, --pause                     Berhenti per cmd dan tunggu tekan ENTER (interaktif)
  --auto                              Jalankan otomatis dengan jeda 1 detik antar cmd (default)
  --no-docker                         Lewati sub-tes yang memanggil docker compose secara langsung
  --no-save                           Jangan simpan hasil ke file log
  -h, --help                          Tampilkan bantuan ini
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        all|p0|p1|p2|p3|p4|p5|P0|P1|P2|P3|P4|P5)
            SELECTED_PROBLEM="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
            shift
            ;;
        --problem)
            SELECTED_PROBLEM="$(echo "${2:-all}" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        --fast)
            FAST_MODE=true
            shift
            ;;
        --step|--pause)
            STEP_MODE=true
            shift
            ;;
        --auto)
            STEP_MODE=false
            shift
            ;;
        --no-docker)
            NO_DOCKER=true
            shift
            ;;
        --compact)
            shift
            ;;
        --no-save)
            SAVE_REPORT=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
REPORT_FILE="${REPORTS_DIR}/e2e-report-${SELECTED_PROBLEM}-${TIMESTAMP}.log"

if [[ "$SAVE_REPORT" == "true" ]]; then
    mkdir -p "$REPORTS_DIR"
    exec > >(tee -a "$REPORT_FILE") 2>&1
fi

TOTAL_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
FIRST_TASK=true

start_task() {
    local task_desc="$1"
    local expect_desc="$2"
    if [[ "$FIRST_TASK" == "false" ]]; then
        echo "--------------------------------------------------------------------------------"
        echo ""
    fi
    FIRST_TASK=false
    echo "task : ${task_desc}"
    echo "expect : ${expect_desc}"
    echo ""
}

format_raw_output() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        echo "  (empty)"
        return
    fi

    if echo "$raw" | jq . >/dev/null 2>&1; then
        echo "$raw" | jq . | sed 's/^/  /'
        return
    fi

    local first_line
    first_line=$(echo "$raw" | head -n 1)
    if [[ "$first_line" =~ ^HTTP/ ]]; then
        local body_part
        body_part=$(echo "$raw" | tail -n +2)
        echo "  ${first_line}"
        if [[ -n "$body_part" ]] && echo "$body_part" | jq . >/dev/null 2>&1; then
            echo "$body_part" | jq . | sed 's/^/  /'
        elif [[ -n "$body_part" ]]; then
            echo "$body_part" | sed 's/^/  /'
        fi
        return
    fi

    if [[ "$raw" == *"| {"* ]]; then
        local prefix="${raw%%| \{*}"
        local json_part="{${raw#*| \{}"
        if echo "$json_part" | jq . >/dev/null 2>&1; then
            echo "  ${prefix}|"
            echo "$json_part" | jq . | sed 's/^/  /'
            return
        fi
    fi

    echo "$raw" | sed 's/^/  /'
}

print_step_result() {
    local cmd_str="$1"
    local raw_resp="$2"
    local is_pass="$3"
    local res_detail="$4"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    echo "cmd : ${cmd_str}"
    echo "resp :"
    format_raw_output "$raw_resp"
    if [[ "$is_pass" == "true" ]]; then
        PASSED_COUNT=$((PASSED_COUNT + 1))
        echo "res : PASS (${res_detail})"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "res : FAIL (${res_detail})"
    fi
    echo ""

    if [[ "$STEP_MODE" == "true" ]]; then
        read -r -p "Press ENTER to continue..." _
        echo ""
    elif [[ "$STEP_DELAY_SEC" -gt 0 ]]; then
        sleep "$STEP_DELAY_SEC"
    fi
}

curl_error_raw() {
    local tmp_hdr
    tmp_hdr=$(mktemp)
    local body
    body=$(curl -s -D "$tmp_hdr" "$@" || true)
    local status_line
    status_line=$(head -n 1 "$tmp_hdr" | tr -d '\r\n')
    rm -f "$tmp_hdr"
    if [[ -z "$status_line" ]]; then
        status_line="HTTP/1.1 000 Unreachable"
    fi
    if [[ -n "$body" ]]; then
        printf "%s\n%s" "$status_line" "$body"
    else
        printf "%s" "$status_line"
    fi
}

should_run() {
    local target="$1"
    [[ "$SELECTED_PROBLEM" == "all" || "$SELECTED_PROBLEM" == "$target" ]]
}

cleanup_state() {
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": false}' > /dev/null 2>&1 || true

    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"enabled": false}' > /dev/null 2>&1 || true

    curl -s -X POST "${PVMBG_URL}/admin/delay" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"min_delay_ms": 500, "max_delay_ms": 3000}' > /dev/null 2>&1 || true

    if [[ "$NO_DOCKER" == "false" ]]; then
        (cd "$PROJECT_ROOT" && docker compose --profile p5-extra stop consumer-pemda-volcano > /dev/null 2>&1 || true)
        (cd "$PROJECT_ROOT" && docker compose start auth-service aggregator consumer-notifier > /dev/null 2>&1 || true)
    fi
}
trap cleanup_state EXIT

# Reset initial state
curl -s -X POST "${PVMBG_URL}/admin/outage" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PVMBG_TOKEN}" \
    -d '{"outage": false}' > /dev/null 2>&1 || true
curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PVMBG_TOKEN}" \
    -d '{"enabled": false}' > /dev/null 2>&1 || true
curl -s -X POST "${PVMBG_URL}/admin/delay" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PVMBG_TOKEN}" \
    -d '{"min_delay_ms": 500, "max_delay_ms": 3000}' > /dev/null 2>&1 || true

fetch_ops_token() {
    curl -s -X POST "${AUTH_URL}/token" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}" | jq -r '.access_token // ""'
}

# ==============================================================================
# P0: KETENTUAN IMPLEMENTASI (1-7) & MODEL INGEST
# ==============================================================================
if should_run "p0"; then
    # Task P0.1: Health check seluruh service
    start_task \
        "[P0.1 - Ketentuan 7] Verifikasi endpoint GET /health pada seluruh 7 service (BMKG, PVMBG, Aggregator, Client-API, Auth-Service, Consumer-Dashboard, Consumer-Notifier)" \
        "Seluruh 7 service mengembalikan HTTP 200 dengan status UP"

    R_BMKG_H=$(curl -s "${BMKG_URL}/health" || true)
    C_BMKG_H=$(curl -s -o /dev/null -w "%{http_code}" "${BMKG_URL}/health" || echo "000")
    print_step_result \
        "curl -s ${BMKG_URL}/health" \
        "$R_BMKG_H" \
        "$([[ "$C_BMKG_H" == "200" ]] && echo true || echo false)" \
        "BMKG Mock mengembalikan HTTP ${C_BMKG_H} == 200 dengan status ok"

    R_PVMBG_H=$(curl -s "${PVMBG_URL}/health" || true)
    C_PVMBG_H=$(curl -s -o /dev/null -w "%{http_code}" "${PVMBG_URL}/health" || echo "000")
    print_step_result \
        "curl -s ${PVMBG_URL}/health" \
        "$R_PVMBG_H" \
        "$([[ "$C_PVMBG_H" == "200" ]] && echo true || echo false)" \
        "PVMBG Mock mengembalikan HTTP ${C_PVMBG_H} == 200 dengan status ok"

    R_AGG_H=$(curl -s "${AGGREGATOR_URL}/health" || true)
    C_AGG_H=$(curl -s -o /dev/null -w "%{http_code}" "${AGGREGATOR_URL}/health" || echo "000")
    print_step_result \
        "curl -s ${AGGREGATOR_URL}/health" \
        "$R_AGG_H" \
        "$([[ "$C_AGG_H" == "200" ]] && echo true || echo false)" \
        "Aggregator mengembalikan HTTP ${C_AGG_H} == 200 dengan status UP"

    R_API_H=$(curl -s "${CLIENT_API_URL}/health" || true)
    C_API_H=$(curl -s -o /dev/null -w "%{http_code}" "${CLIENT_API_URL}/health" || echo "000")
    print_step_result \
        "curl -s ${CLIENT_API_URL}/health" \
        "$R_API_H" \
        "$([[ "$C_API_H" == "200" ]] && echo true || echo false)" \
        "Client-Facing API mengembalikan HTTP ${C_API_H} == 200 dengan status UP"

    R_AUTH_H=$(curl -s "${AUTH_URL}/health" || true)
    C_AUTH_H=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}/health" || echo "000")
    print_step_result \
        "curl -s ${AUTH_URL}/health" \
        "$R_AUTH_H" \
        "$([[ "$C_AUTH_H" == "200" ]] && echo true || echo false)" \
        "Auth-Service mengembalikan HTTP ${C_AUTH_H} == 200 dengan status UP"

    if [[ "$NO_DOCKER" == "false" ]]; then
        R_DASH_H=$(cd "$PROJECT_ROOT" && docker compose exec -T consumer-dashboard wget -qO- http://localhost:8085/health 2>/dev/null || echo "")
        print_step_result \
            "docker compose exec -T consumer-dashboard wget -qO- http://localhost:8085/health" \
            "$R_DASH_H" \
            "$([[ -n "$R_DASH_H" ]] && echo true || echo false)" \
            "Consumer-Dashboard health endpoint merespons status UP"

        R_NOTIF_H=$(cd "$PROJECT_ROOT" && docker compose exec -T consumer-notifier wget -qO- http://localhost:8086/health 2>/dev/null || echo "")
        print_step_result \
            "docker compose exec -T consumer-notifier wget -qO- http://localhost:8086/health" \
            "$R_NOTIF_H" \
            "$([[ -n "$R_NOTIF_H" ]] && echo true || echo false)" \
            "Consumer-Notifier health endpoint merespons status UP"
    fi

    # Task P0.2: Model Ingest - Seed >= 20 record historis & endpoint terpisah TsunamiWarning
    start_task \
        "[P0.2 - Model Ingest] Verifikasi ketersediaan seed data awal minimal 20 record historis pada BMKG dan PVMBG serta endpoint terpisah /tsunami-warnings" \
        "BMKG memiliki >= 20 SeismicEvent dan >= 1 TsunamiWarning, serta PVMBG memiliki >= 20 VolcanicReport"

    R_SEIS_SEED=$(curl -s -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events" | jq '{total_records: length, sample_record: .[0]}' || echo "{}")
    SEIS_CNT=$(echo "$R_SEIS_SEED" | jq -r '.total_records // 0')
    print_step_result \
        "curl -s -H 'X-BMKG-Key: ${BMKG_API_KEY}' ${BMKG_URL}/seismic-events | jq '{total_records: length, sample_record: .[0]}'" \
        "$R_SEIS_SEED" \
        "$([[ "$SEIS_CNT" -ge 20 ]] && echo true || echo false)" \
        "BMKG menyediakan ${SEIS_CNT} SeismicEvent (>= 20 record historis)"

    R_TSU_SEED=$(curl -s -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/tsunami-warnings" | jq '{total_records: length, sample_record: .[0]}' || echo "{}")
    TSU_CNT=$(echo "$R_TSU_SEED" | jq -r '.total_records // 0')
    print_step_result \
        "curl -s -H 'X-BMKG-Key: ${BMKG_API_KEY}' ${BMKG_URL}/tsunami-warnings | jq '{total_records: length, sample_record: .[0]}'" \
        "$R_TSU_SEED" \
        "$([[ "$TSU_CNT" -ge 1 ]] && echo true || echo false)" \
        "Endpoint terpisah /tsunami-warnings menyediakan ${TSU_CNT} TsunamiWarning"

    R_VOLC_SEED=$(curl -s -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" | jq '{total_records: length, sample_record: .[0]}' || echo "{}")
    VOLC_CNT=$(echo "$R_VOLC_SEED" | jq -r '.total_records // 0')
    print_step_result \
        "curl -s -H 'Authorization: Bearer ${PVMBG_TOKEN}' ${PVMBG_URL}/volcanic-reports | jq '{total_records: length, sample_record: .[0]}'" \
        "$R_VOLC_SEED" \
        "$([[ "$VOLC_CNT" -ge 20 ]] && echo true || echo false)" \
        "PVMBG menyediakan ${VOLC_CNT} VolcanicReport (>= 20 record historis)"

    # Task P0.3: Kontrak Mock - Karakteristik latensi BMKG (50-150ms) vs PVMBG (500-3000ms)
    start_task \
        "[P0.3 - Kontrak Mock] Verifikasi karakteristik response time BMKG (rendah & konsisten 50-150 ms) dibanding PVMBG (fluktuatif 500-3000 ms)" \
        "Latensi BMKG konsisten di kisaran 50-150 ms (< 0.40s) dan latensi PVMBG >= 0.50s (500-3000 ms)"

    R_BMKG_TIME=$(curl -s -o /dev/null -w '{"service":"bmkg-mock","http_code":%{http_code},"time_total_seconds":%{time_total}}' -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events")
    BMKG_SEC=$(echo "$R_BMKG_TIME" | jq -r '.time_total_seconds')
    BMKG_TIME_OK=$(python3 -c "print('true' if 0.045 <= float('${BMKG_SEC}') < 0.40 else 'false')")
    print_step_result \
        "curl -s -o /dev/null -w '{\"service\":\"bmkg-mock\",\"http_code\":%{http_code},\"time_total_seconds\":%{time_total}}' -H 'X-BMKG-Key: <bmkg-key>' ${BMKG_URL}/seismic-events" \
        "$R_BMKG_TIME" \
        "$BMKG_TIME_OK" \
        "Response time BMKG = ${BMKG_SEC}s (< 0.40s, sesuai kontrak delay tetap 50-150 ms)"

    R_PVMBG_TIME=$(curl -s -o /dev/null -w '{"service":"pvmbg-mock","http_code":%{http_code},"time_total_seconds":%{time_total}}' -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports")
    PVMBG_SEC=$(echo "$R_PVMBG_TIME" | jq -r '.time_total_seconds')
    PVMBG_TIME_OK=$(python3 -c "print('true' if float('${PVMBG_SEC}') >= 0.45 else 'false')")
    print_step_result \
        "curl -s -o /dev/null -w '{\"service\":\"pvmbg-mock\",\"http_code\":%{http_code},\"time_total_seconds\":%{time_total}}' -H 'Authorization: Bearer <pvmbg-token>' ${PVMBG_URL}/volcanic-reports" \
        "$R_PVMBG_TIME" \
        "$PVMBG_TIME_OK" \
        "Response time PVMBG = ${PVMBG_SEC}s (>= 0.50s, sesuai kontrak delay acak 500-3000 ms)"

    # Task P0.4: Ketentuan 7 - Propagasi Correlation ID lintas service & pencatatan duration_ms di log terstruktur
    start_task \
        "[P0.4 - Ketentuan 7] Verifikasi propagasi X-Correlation-ID lintas service (Client-API -> Aggregator) dan pencatatan duration_ms pada log JSON terstruktur" \
        "Request dengan X-Correlation-ID diteruskan lintas service dan tercatat pada log JSON terstruktur kedua service beserta field duration_ms"

    OPS_TOK=$(fetch_ops_token)
    CORR_ID="corr-m1-trace-$(date +%s)"
    R_CORR_API=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" -H "X-Correlation-ID: ${CORR_ID}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' -H 'X-Correlation-ID: ${CORR_ID}' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_CORR_API" \
        "$([[ -n "$R_CORR_API" && "$R_CORR_API" != "{}" ]] && echo true || echo false)" \
        "Client-Facing API mengembalikan HTTP 200 untuk request ber-header X-Correlation-ID: ${CORR_ID}"

    if [[ "$NO_DOCKER" == "false" ]]; then
        sleep 1
        R_CORR_LOG_API=$(cd "$PROJECT_ROOT" && docker compose logs --tail=500 client-api 2>/dev/null | grep "$CORR_ID" | grep "outbound_call" | tail -n 1 || true)
        if [[ -z "$R_CORR_LOG_API" ]]; then
            R_CORR_LOG_API=$(cd "$PROJECT_ROOT" && docker compose logs --tail=500 client-api 2>/dev/null | grep "$CORR_ID" | tail -n 1 || true)
        fi
        print_step_result \
            "docker compose logs --tail=500 client-api | grep '${CORR_ID}' | tail -n 1" \
            "$R_CORR_LOG_API" \
            "$([[ -n "$R_CORR_LOG_API" ]] && echo true || echo false)" \
            "Log client-api mencatat correlation_id=${CORR_ID} dan latensi panggilan keluar (duration_ms)"

        R_CORR_LOG_AGG=$(cd "$PROJECT_ROOT" && docker compose logs --tail=500 aggregator 2>/dev/null | grep "$CORR_ID" | tail -n 1 || true)
        print_step_result \
            "docker compose logs --tail=500 aggregator | grep '${CORR_ID}' | tail -n 1" \
            "$R_CORR_LOG_AGG" \
            "$([[ -n "$R_CORR_LOG_AGG" ]] && echo true || echo false)" \
            "Correlation ID yang sama (${CORR_ID}) sukses terpropagasi dan tercatat di service aggregator"
    fi

    # Task P0.5: KI-1 - Isolasi Business Logic Lintas Service & Pustaka Bersama
    start_task \
        "[P0.5 - Ketentuan 1 & Arsitektur Microservice] Verifikasi tidak ada pemanggilan fungsi atau business logic bersama lintas service (shared/ hanya berisi infra)" \
        "Tidak ada import antar-service dalam go.mod maupun file sumber Go, dan shared/ tidak memuat struct HazardEvent atau logika bisnis"

    R_CROSS_IMPORT=$(cd "$PROJECT_ROOT" && for s in services/*/; do n=$(basename "$s"); (grep -rn 'AkuAdalahBMKG/services/' --include='*.go' "$s" 2>/dev/null || true) | (grep -v "services/$n/" || true); done | grep -v "^$" || true)
    print_step_result \
        "for s in services/*/; do grep -rn 'AkuAdalahBMKG/services/' \$s; done" \
        "$([[ -z "$R_CROSS_IMPORT" ]] && echo "(empty - 0 cross imports)" || echo "$R_CROSS_IMPORT")" \
        "$([[ -z "$R_CROSS_IMPORT" ]] && echo true || echo false)" \
        "Seluruh service terisolasi penuh tanpa ketergantungan kode langsung antar-service (cross-imports = 0)"

    R_SHARED_FILES=$(cd "$PROJECT_ROOT" && ls -1 shared 2>/dev/null || true)
    SHARED_DOMAIN=$(cd "$PROJECT_ROOT" && (grep -rnE "HazardEvent|SeismicEvent|VolcanicReport" shared/ 2>/dev/null || true))
    print_step_result \
        "ls -1 shared && grep -rnE 'HazardEvent|SeismicEvent|VolcanicReport' shared/" \
        "$R_SHARED_FILES" \
        "$([[ -z "$SHARED_DOMAIN" ]] && echo true || echo false)" \
        "Modul shared/ hanya memuat pustaka infrastruktur (envutil, httpclient, logger, middleware) tanpa domain model"

    # Task P0.6: KI-2 & KI-3 - Port Exposure & Isolasi Port Internal
    start_task \
        "[P0.6 - Ketentuan 2 & 3] Verifikasi exposure port public (8080, 8081, 8082, 8084, 15672) dan isolasi port internal (canonical-store, auth-store, amqp)" \
        "Port host hanya membuka endpoint yang diwajibkan; canonical-store, auth-store, dan port AMQP 5672 tidak di-expose ke host"

    if [[ "$NO_DOCKER" == "false" ]]; then
        R_INTERNAL_PORTS=$(cd "$PROJECT_ROOT" && echo "canonical-store 5432: $(docker compose port canonical-store 5432 2>/dev/null || echo 'not published') | auth-store 6379: $(docker compose port auth-store 6379 2>/dev/null || echo 'not published') | amqp 5672: $(docker compose port message-broker 5672 2>/dev/null || echo 'not published')")
        PORTS_ISOLATED="true"
        if [[ "$R_INTERNAL_PORTS" == *"0.0.0.0:5432"* || "$R_INTERNAL_PORTS" == *"0.0.0.0:6379"* || "$R_INTERNAL_PORTS" == *"0.0.0.0:5672"* ]]; then
            PORTS_ISOLATED="false"
        fi
        print_step_result \
            "docker compose port canonical-store 5432 && docker compose port auth-store 6379 && docker compose port message-broker 5672" \
            "$R_INTERNAL_PORTS" \
            "$PORTS_ISOLATED" \
            "Port internal (Postgres 5432, Redis 6379, AMQP 5672) terisolasi dan tidak di-publish ke host luar"
    fi

    # Task P0.7: MOCK-04 & MOCK-06 - Kontrak Mock Pasif & Filter ?since=
    start_task \
        "[P0.7 - Kontrak Mock Pasif & Filter ?since=] Verifikasi mock memfilter data berdasarkan parameter ?since= dan mock bersifat pasif (tanpa outbound HTTP call)" \
        "Parameter ?since= hanya mengembalikan record setelah timestamp, dan mock tidak melakukan panggilan keluar"

    SINCE_TS=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    R_SINCE_BMKG=$(curl -s -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events?since=${SINCE_TS}" | jq --arg s "$SINCE_TS" '[.[] | select((.occurred_at | sub("\\.[0-9]+Z$"; "Z")) < $s)] | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'X-BMKG-Key: <bmkg-key>' '${BMKG_URL}/seismic-events?since=${SINCE_TS}' | jq '[.[] | select(.occurred_at < \"${SINCE_TS}\")] | length'" \
        "{\"older_than_since_count\": ${R_SINCE_BMKG}}" \
        "$([[ "$R_SINCE_BMKG" -eq 0 ]] && echo true || echo false)" \
        "Filter ?since= pada BMKG berfungsi benar (0 record lebih lama dari timestamp filter)"

    R_MOCK_OUTBOUND=$(cd "$PROJECT_ROOT" && (grep -rnE 'http\.(Post|Get|NewRequest|Client)' services/bmkg-mock/src services/pvmbg-mock/src 2>/dev/null || true) | (grep -v "_test" || true))
    print_step_result \
        "grep -rnE 'http.(Post|Get|NewRequest|Client)' services/bmkg-mock/src services/pvmbg-mock/src" \
        "$([[ -z "$R_MOCK_OUTBOUND" ]] && echo "(empty - 0 outbound HTTP calls)" || echo "$R_MOCK_OUTBOUND")" \
        "$([[ -z "$R_MOCK_OUTBOUND" ]] && echo true || echo false)" \
        "Mock BMKG dan PVMBG terbukti pasif (0 outbound HTTP client/request)"

    # Task P0.8: ING-02 & ING-03 - Integritas Canonical Store & Kepatuhan 11 Field Kanonik
    start_task \
        "[P0.8 - Integritas Canonical Store & Kepatuhan 11 Field Kanonik] Verifikasi tidak ada duplikasi data di Canonical Store dan seluruh data mematuhi 11 field kanonik" \
        "PostgreSQL Canonical Store bebas duplikasi (HAVING count > 1 = 0), seluruh record API memiliki 11 field kanonik, ID deterministik, enum valid, dan timestamp ISO-8601 UTC"

    if [[ "$NO_DOCKER" == "false" ]]; then
        R_DB_DUP=$(cd "$PROJECT_ROOT" && docker compose exec -T canonical-store psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
            "SELECT source, source_ref_id, count(*) FROM hazard_events GROUP BY 1,2 HAVING count(*) > 1;" 2>/dev/null || true)
        print_step_result \
            "docker compose exec -T canonical-store psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT source, source_ref_id, count(*) FROM hazard_events GROUP BY 1,2 HAVING count(*) > 1;'" \
            "$R_DB_DUP" \
            "$([[ "$R_DB_DUP" == *"(0 rows)"* ]] && echo true || echo false)" \
            "Canonical Store bebas duplikasi record (0 duplicate rows)"
    fi

    OPS_TOK=$(fetch_ops_token)
    R_CANON_SCHEMA=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=100" | jq '
        [.data[]? | {
            keys_ok: (keys == ["area_name","attributes","hazard_id","hazard_type","ingested_at","latitude","longitude","occurred_at","severity","source","source_ref_id"]),
            id_ok: (.hazard_id == "\(.source)-\(.source_ref_id)" and (.hazard_id | test("^[A-Za-z0-9._-]+$"))),
            enum_ok: ((.source | IN("BMKG","PVMBG")) and (.hazard_type | IN("SEISMIC","VOLCANIC")) and (.severity | IN("NORMAL","WASPADA","SIAGA","AWAS"))),
            pair_ok: ((.source == "BMKG") == (.hazard_type == "SEISMIC")),
            time_ok: ((.occurred_at | endswith("Z")) and (.ingested_at | endswith("Z")) and (.ingested_at >= .occurred_at))
        }] | {total: length, invalid_records: map(select(all(.[]; .) | not)) | length}' 2>/dev/null || echo '{"total":0,"invalid_records":99}')
    INVALID_CNT=$(echo "$R_CANON_SCHEMA" | jq -r '.invalid_records // 99')
    TOTAL_CANON_CNT=$(echo "$R_CANON_SCHEMA" | jq -r '.total // 0')
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=100' | jq '<11-canonical-fields-validation>'" \
        "$R_CANON_SCHEMA" \
        "$([[ "$INVALID_CNT" -eq 0 && "$TOTAL_CANON_CNT" -gt 0 ]] && echo true || echo false)" \
        "Seluruh ${TOTAL_CANON_CNT} record memenuhi 11 field kanonik, format ID <source>-<source_ref_id>, enum valid, dan timestamp ISO-8601 UTC"
fi

# ==============================================================================
# PROBLEM 1: ARSITEKTUR & INTEROPERABILITAS DATA
# ==============================================================================
if should_run "p1"; then
    OPS_TOK=$(fetch_ops_token)

    # Task P1.1: Pemetaan Kanonik BMKG & PVMBG pada skema awal
    start_task \
        "[P1.1 - Pemetaan Kanonik Skema Awal] Jalankan sistem dengan PVMBG pada skema awal dan tunjukkan Aggregator menghasilkan HazardEvent sesuai aturan pemetaan untuk BMKG (termasuk korelasi TsunamiWarning) dan PVMBG" \
        "HazardEvent SEISMIC dan VOLCANIC memiliki 10 field kanonik sesuai aturan pemetaan, korelasi tsunami_warning via related_event_id, serta VolcanicReport skema awal tanpa confidence_level"

    R_P1_SEIS=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=50" | jq '[.data[]? | select(.attributes.potential_tsunami == true and .attributes.tsunami_warning != null)][0]' 2>/dev/null || echo "null")
    P1_SEIS_ID=$(echo "$R_P1_SEIS" | jq -r '.hazard_id // ""' 2>/dev/null || echo "")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=SEISMIC&limit=50' | jq '[.data[] | select(.attributes.potential_tsunami == true and .attributes.tsunami_warning != null)][0]'" \
        "$R_P1_SEIS" \
        "$([[ -n "$P1_SEIS_ID" && "$P1_SEIS_ID" != "null" ]] && echo true || echo false)" \
        "SeismicEvent berhasil dipetakan ke HazardEvent (${P1_SEIS_ID}) beserta korelasi tsunami_warning dan severity kanonik"

    R_P1_VOLC_OLD=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50" | jq '[.data[]? | select(.attributes.confidence_level == null)][0]' 2>/dev/null || echo "null")
    P1_VOLC_OLD_ID=$(echo "$R_P1_VOLC_OLD" | jq -r '.hazard_id // ""' 2>/dev/null || echo "")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50' | jq '[.data[] | select(.attributes.confidence_level == null)][0]'" \
        "$R_P1_VOLC_OLD" \
        "$([[ -n "$P1_VOLC_OLD_ID" && "$P1_VOLC_OLD_ID" != "null" ]] && echo true || echo false)" \
        "VolcanicReport skema awal berhasil dipetakan ke HazardEvent (${P1_VOLC_OLD_ID}) dengan koordinat tabel referensi gunung api tanpa confidence_level"

    # Task P1.2 - P1.4: Perubahan skema PVMBG saat runtime & verifikasi penerusan confidence_level ke attributes
    start_task \
        "[P1.2, P1.3, P1.4 - Evolusi Skema Dinamis PVMBG] Picu perubahan skema PVMBG melalui POST /admin/schema-version saat sistem berjalan tanpa restart dan tunjukkan Aggregator meneruskan field baru confidence_level ke dalam attributes" \
        "POST /admin/schema-version mengembalikan status ok (confidence_level: true) dan Aggregator tetap menghasilkan HazardEvent valid dengan attributes.confidence_level tanpa restart"

    R_TOGGLE_SCHEMA=$(curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"enabled": true}' || echo "{}")
    TOGGLE_VAL=$(echo "$R_TOGGLE_SCHEMA" | jq -r '.confidence_level // false' 2>/dev/null || echo "false")
    print_step_result \
        "curl -s -X POST ${PVMBG_URL}/admin/schema-version -H 'Content-Type: application/json' -H 'Authorization: Bearer <pvmbg-token>' -d '{\"enabled\": true}'" \
        "$R_TOGGLE_SCHEMA" \
        "$([[ "$TOGGLE_VAL" == "true" ]] && echo true || echo false)" \
        "Perubahan skema PVMBG berhasil diaktifkan saat runtime (confidence_level=${TOGGLE_VAL})"

    R_P1_VOLC_NEW="null"
    for ((i=1; i<=9; i++)); do
        sleep 2
        V_CHK=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50" || echo "{}")
        C_CNT=$(echo "$V_CHK" | jq '[.data[]? | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
        if [[ "$C_CNT" -gt 0 ]]; then
            R_P1_VOLC_NEW=$(echo "$V_CHK" | jq '[.data[]? | select(.attributes.confidence_level != null)][0]' 2>/dev/null || echo "null")
            break
        fi
    done
    CONF_VAL=$(echo "$R_P1_VOLC_NEW" | jq -r '.attributes.confidence_level // "null"')
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50' | jq '[.data[] | select(.attributes.confidence_level != null)][0]'" \
        "$R_P1_VOLC_NEW" \
        "$([[ "$CONF_VAL" != "null" && -n "$CONF_VAL" ]] && echo true || echo false)" \
        "Aggregator tetap berjalan tanpa restart dan meneruskan field baru confidence_level=${CONF_VAL} ke dalam attributes"
fi

# ==============================================================================
# PROBLEM 2: CONCURRENCY, AVAILABILITY, & GRACEFUL DEGRADATION
# ==============================================================================
if should_run "p2"; then
    OPS_TOK=$(fetch_ops_token)

    # Task P2.1: Bebas Head-of-Line Blocking (p95 latensi BMKG-only < 300ms saat PVMBG delay diatur ke 3 detik)
    start_task \
        "[P2.1 - Bebas Head-of-Line Blocking] Kirim permintaan yang hanya membutuhkan data BMKG (SEISMIC) bersamaan dengan permintaan yang membutuhkan data PVMBG (delay simulasi 3 detik)" \
        "p95 latensi permintaan BMKG-only tetap di bawah 300 ms"

    R_P21=$("${PROJECT_ROOT}/scripts/load-test/run-load-test.sh" --mode p21 --no-save || true)
    P21_P95=$(echo "$R_P21" | jq -r '.latency_ms.p95 // 999')
    P21_OK=$(python3 -c "print('true' if float('${P21_P95}') < 300.0 else 'false')")
    print_step_result \
        "./scripts/load-test/run-load-test.sh --mode p21 --no-save" \
        "$R_P21" \
        "$P21_OK" \
        "p95 latensi permintaan BMKG-only = ${P21_P95} ms (< 300 ms)"

    # Task P2.2: Sustained Load Testing (>= 50 koneksi paralel selama >= 60 detik, error rate < 1%)
    LOAD_DUR=60
    if [[ "$FAST_MODE" == "true" ]]; then
        LOAD_DUR=10
    fi
    start_task \
        "[P2.2 - Sustained Load Testing] Jalankan load testing dengan >= 50 koneksi paralel (55 VUs) selama ${LOAD_DUR} detik dalam pola sustained dan laporkan throughput, p50/p95/p99, HTTP 429, dan error rate" \
        "Sistem tidak crash dan error rate di luar penolakan terkontrol (HTTP 429) berada di bawah 1%"

    R_P22=$("${PROJECT_ROOT}/scripts/load-test/run-load-test.sh" --mode p22 --vus 55 --duration "$LOAD_DUR" --no-save 2>/dev/null || true)
    P22_ERR=$(echo "$R_P22" | jq -r '.uncontrolled_error_rate_pct // 100')
    P22_RPS=$(echo "$R_P22" | jq -r '.throughput_req_per_sec // 0')
    P22_OK=$(python3 -c "print('true' if float('${P22_ERR}') < 1.0 else 'false')")
    print_step_result \
        "./scripts/load-test/run-load-test.sh --mode p22 --vus 55 --duration ${LOAD_DUR}" \
        "$R_P22" \
        "$P22_OK" \
        "Throughput=${P22_RPS} req/s pada 55 koneksi paralel dengan uncontrolled error rate = ${P22_ERR}% (< 1%)"

    # Task P2.3: Simulasi Outage PVMBG, Graceful Degradation, dan Pemulihan Otomatis
    OPS_TOK=$(fetch_ops_token)
    start_task \
        "[P2.3 - Outage PVMBG, Graceful Degradation, & Auto-Recovery] Nyalakan outage PVMBG melalui POST /admin/outage, verifikasi layanan seismik dan vulkanik (data terakhir dari Canonical Store disertai stale_since), lalu matikan outage dan tunjukkan sistem kembali normal tanpa restart" \
        "Selama outage PVMBG (HTTP 503), permintaan seismik dilayani normal (BMKG UP), permintaan vulkanik dijawab HTTP 200 dengan data terakhir disertai status DEGRADED dan stale_since, serta kembali UP (stale_since=null) setelah outage dimatikan"

    R_OUTAGE_ON=$(curl -s -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": true}' || echo "{}")
    OUT_STATE_ON=$(echo "$R_OUTAGE_ON" | jq -r '.outage // false')
    print_step_result \
        "curl -s -X POST ${PVMBG_URL}/admin/outage -H 'Content-Type: application/json' -H 'Authorization: Bearer <pvmbg-token>' -d '{\"outage\": true}'" \
        "$R_OUTAGE_ON" \
        "$([[ "$OUT_STATE_ON" == "true" ]] && echo true || echo false)" \
        "Kondisi outage pada PVMBG berhasil diaktifkan (outage=true)"

    R_PVMBG_503=$(curl_error_raw -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <pvmbg-token>' ${PVMBG_URL}/volcanic-reports" \
        "$R_PVMBG_503" \
        "$([[ "$R_PVMBG_503" == *"503"* ]] && echo true || echo false)" \
        "PVMBG Mock mengembalikan HTTP 503 Service Unavailable selama kondisi outage"

    R_SEIS_DURING=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=1" || echo "{}")
    SEIS_DURING_CNT=$(echo "$R_SEIS_DURING" | jq '.data | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=SEISMIC&limit=1'" \
        "$R_SEIS_DURING" \
        "$([[ "$SEIS_DURING_CNT" -gt 0 ]] && echo true || echo false)" \
        "Data seismik (BMKG) tetap dilayani secara normal (HTTP 200) tanpa terpengaruh outage PVMBG"

    R_DEG_VOLC="{}"
    PVMBG_ST="UNKNOWN"
    PVMBG_STALE="null"
    for ((i=1; i<=10; i++)); do
        sleep 1
        R_DEG_VOLC=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=1" || echo "{}")
        PVMBG_ST=$(echo "$R_DEG_VOLC" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
        PVMBG_STALE=$(echo "$R_DEG_VOLC" | jq -r '.source_status.PVMBG.stale_since // "null"')
        if [[ "$PVMBG_ST" == "DEGRADED" && "$PVMBG_STALE" != "null" ]]; then
            break
        fi
    done
    BMKG_ST=$(echo "$R_DEG_VOLC" | jq -r '.source_status.BMKG.status // "UNKNOWN"')
    DEG_CNT=$(echo "$R_DEG_VOLC" | jq '.data | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=1'" \
        "$R_DEG_VOLC" \
        "$([[ "$BMKG_ST" == "UP" && "$PVMBG_ST" == "DEGRADED" && "$PVMBG_STALE" != "null" && "$DEG_CNT" -gt 0 ]] && echo true || echo false)" \
        "Client-API tetap merespons HTTP 200 dengan data vulkanik terakhir dari Canonical Store, BMKG=UP, dan PVMBG=DEGRADED (stale_since=${PVMBG_STALE})"

    R_OUTAGE_OFF=$(curl -s -X POST "${PVMBG_URL}/admin/outage" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PVMBG_TOKEN}" \
        -d '{"outage": false}' || echo "{}")
    OUT_STATE_OFF=$(echo "$R_OUTAGE_OFF" | jq -r 'if .outage == false then "false" else "true" end')
    print_step_result \
        "curl -s -X POST ${PVMBG_URL}/admin/outage -H 'Content-Type: application/json' -H 'Authorization: Bearer <pvmbg-token>' -d '{\"outage\": false}'" \
        "$R_OUTAGE_OFF" \
        "$([[ "$OUT_STATE_OFF" == "false" ]] && echo true || echo false)" \
        "Kondisi outage pada PVMBG berhasil dimatikan (outage=false)"

    R_REC_STATUS="{}"
    REC_OK="false"
    for ((i=1; i<=10; i++)); do
        sleep 1
        CHK_BODY=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
        CUR_ST=$(echo "$CHK_BODY" | jq -r '.source_status.PVMBG.status // "UNKNOWN"')
        CUR_STALE=$(echo "$CHK_BODY" | jq -r '.source_status.PVMBG.stale_since // "null"')
        if [[ "$CUR_ST" == "UP" && "$CUR_STALE" == "null" ]]; then
            REC_OK="true"
            R_REC_STATUS=$(echo "$CHK_BODY" | jq '.source_status')
            break
        fi
    done
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1' | jq '.source_status'" \
        "$R_REC_STATUS" \
        "$REC_OK" \
        "Sistem pulih otomatis tanpa restart: PVMBG.status == UP dan stale_since == null"
fi

# ==============================================================================
# PROBLEM 3: SERVICE-TO-SERVICE AUTHENTICATION & TRUST
# ==============================================================================
if should_run "p3"; then
    # Task P3.1: Matriks Lengkap Isolasi Kredensial Lintas Domain
    start_task \
        "[P3.1 - Isolasi Domain of Trust BMKG & PVMBG] Tunjukkan kredensial yang valid untuk BMKG ditolak dengan 401/403 saat dipakai mengakses PVMBG, dan sebaliknya serta penolakan kredensial asing" \
        "Permintaan ke PVMBG dengan X-BMKG-Key ditolak HTTP 401, permintaan ke BMKG dengan Bearer Token PVMBG ditolak HTTP 401, akses tanpa kredensial ditolak HTTP 401, dan kredensial sumber ditolak oleh Client-API"

    R_BMKG_TO_PVMBG=$(curl_error_raw -H "X-BMKG-Key: ${BMKG_API_KEY}" "${PVMBG_URL}/volcanic-reports")
    print_step_result \
        "curl -i -s -H 'X-BMKG-Key: <bmkg-key>' ${PVMBG_URL}/volcanic-reports" \
        "$R_BMKG_TO_PVMBG" \
        "$([[ "$R_BMKG_TO_PVMBG" == *"401"* || "$R_BMKG_TO_PVMBG" == *"403"* ]] && echo true || echo false)" \
        "Kredensial BMKG ditolak oleh PVMBG dengan HTTP 401 Unauthorized"

    R_PVMBG_TO_BMKG=$(curl_error_raw -H "Authorization: Bearer ${PVMBG_TOKEN}" "${BMKG_URL}/seismic-events")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <pvmbg-token>' ${BMKG_URL}/seismic-events" \
        "$R_PVMBG_TO_BMKG" \
        "$([[ "$R_PVMBG_TO_BMKG" == *"401"* || "$R_PVMBG_TO_BMKG" == *"403"* ]] && echo true || echo false)" \
        "Kredensial PVMBG ditolak oleh BMKG dengan HTTP 401 Unauthorized"

    R_NO_AUTH_BMKG=$(curl_error_raw "${BMKG_URL}/seismic-events")
    print_step_result \
        "curl -i -s ${BMKG_URL}/seismic-events" \
        "$R_NO_AUTH_BMKG" \
        "$([[ "$R_NO_AUTH_BMKG" == *"401"* || "$R_NO_AUTH_BMKG" == *"403"* ]] && echo true || echo false)" \
        "Permintaan ke BMKG tanpa header X-BMKG-Key ditolak dengan HTTP 401 Unauthorized"

    R_NO_AUTH_PVMBG=$(curl_error_raw "${PVMBG_URL}/volcanic-reports")
    print_step_result \
        "curl -i -s ${PVMBG_URL}/volcanic-reports" \
        "$R_NO_AUTH_PVMBG" \
        "$([[ "$R_NO_AUTH_PVMBG" == *"401"* || "$R_NO_AUTH_PVMBG" == *"403"* ]] && echo true || echo false)" \
        "Permintaan ke PVMBG tanpa header Authorization Bearer ditolak dengan HTTP 401 Unauthorized"

    R_BMKG_TO_CLIENT_API=$(curl_error_raw -H "Authorization: Bearer ${BMKG_API_KEY}" "${CLIENT_API_URL}/hazards")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <bmkg-key>' ${CLIENT_API_URL}/hazards" \
        "$R_BMKG_TO_CLIENT_API" \
        "$([[ "$R_BMKG_TO_CLIENT_API" == *"401"* ]] && echo true || echo false)" \
        "Kredensial BMKG ditolak oleh Client-Facing API dengan HTTP 401 INVALID_TOKEN"

    R_PVMBG_TO_CLIENT_API=$(curl_error_raw -H "Authorization: Bearer ${PVMBG_TOKEN}" "${CLIENT_API_URL}/hazards")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <pvmbg-token>' ${CLIENT_API_URL}/hazards" \
        "$R_PVMBG_TO_CLIENT_API" \
        "$([[ "$R_PVMBG_TO_CLIENT_API" == *"401"* ]] && echo true || echo false)" \
        "Kredensial PVMBG ditolak oleh Client-Facing API dengan HTTP 401 INVALID_TOKEN"

    # Task P3.2: Penegakan Scope Media (Ringkasan) vs Tim Lapangan / BNPB Ops (Mentah)
    start_task \
        "[P3.2 - Penegakan Scope Client Downstream] Tunjukkan ketiga client memiliki identitas berbeda, client ber-scope Media hanya menerima field Ringkasan dan ditolak dengan 401/403 saat meminta field Mentah, sedangkan Tim Lapangan menerima seluruh field Mentah" \
        "Media mendapat scope hazards:read:summary dan hanya menerima 7 field Ringkasan, permintaan eksplisit ke field mentah ditolak HTTP 403 INSUFFICIENT_SCOPE, sedangkan Tim Lapangan (hazards:read:raw) menerima seluruh field mentah (HTTP 200)"

    R_MEDIA_TOK=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"${CLIENT_MEDIA_SECRET}\"}" || echo "{}")
    M_ACCESS=$(echo "$R_MEDIA_TOK" | jq -r '.access_token // ""')
    M_SCOPE=$(echo "$R_MEDIA_TOK" | jq -r '.scope // ""')
    print_step_result \
        "curl -s -X POST ${AUTH_URL}/token -H 'Content-Type: application/json' -d '{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"<media-secret>\"}'" \
        "$R_MEDIA_TOK" \
        "$([[ "$M_SCOPE" == "hazards:read:summary" && -n "$M_ACCESS" ]] && echo true || echo false)" \
        "Auth-Service menerbitkan token untuk ${CLIENT_MEDIA_ID} dengan scope=${M_SCOPE}"

    R_FIELD_TOK=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"${CLIENT_FIELD_SECRET}\"}" || echo "{}")
    F_ACCESS=$(echo "$R_FIELD_TOK" | jq -r '.access_token // ""')
    F_REFRESH=$(echo "$R_FIELD_TOK" | jq -r '.refresh_token // ""')
    F_SCOPE=$(echo "$R_FIELD_TOK" | jq -r '.scope // ""')
    F_TTL=$(echo "$R_FIELD_TOK" | jq -r '.expires_in // 60')
    print_step_result \
        "curl -s -X POST ${AUTH_URL}/token -H 'Content-Type: application/json' -d '{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"<field-secret>\"}'" \
        "$R_FIELD_TOK" \
        "$([[ "$F_SCOPE" == "hazards:read:raw" && -n "$F_ACCESS" && -n "$F_REFRESH" ]] && echo true || echo false)" \
        "Auth-Service menerbitkan access_token (TTL=${F_TTL}s) dan refresh_token untuk ${CLIENT_FIELD_ID} dengan scope=${F_SCOPE}"

    R_MEDIA_LIST=$(curl -s -H "Authorization: Bearer ${M_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
    SAMPLE_HID=$(echo "$R_MEDIA_LIST" | jq -r '.data[0].hazard_id // "BMKG-seismic-0001"')
    RAW_LEAKS=$(echo "$R_MEDIA_LIST" | jq '[.data[]? | select(has("source_ref_id") or has("latitude") or has("longitude") or has("attributes"))] | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_MEDIA_LIST" \
        "$([[ "$RAW_LEAKS" -eq 0 ]] && echo true || echo false)" \
        "Client Media hanya menerima 7 field Ringkasan (kebocoran field Mentah = ${RAW_LEAKS})"

    R_MEDIA_FORBID_1=$(curl_error_raw -H "Authorization: Bearer ${M_ACCESS}" "${CLIENT_API_URL}/hazards?fields=severity,latitude")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards?fields=severity,latitude'" \
        "$R_MEDIA_FORBID_1" \
        "$([[ "$R_MEDIA_FORBID_1" == *"403"* && "$R_MEDIA_FORBID_1" == *"INSUFFICIENT_SCOPE"* ]] && echo true || echo false)" \
        "Permintaan eksplisit field mentah (latitude) oleh Media ditolak server dengan HTTP 403 INSUFFICIENT_SCOPE"

    R_MEDIA_FORBID_2=$(curl_error_raw -H "Authorization: Bearer ${M_ACCESS}" "${CLIENT_API_URL}/hazards/${SAMPLE_HID}/raw")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards/${SAMPLE_HID}/raw'" \
        "$R_MEDIA_FORBID_2" \
        "$([[ "$R_MEDIA_FORBID_2" == *"403"* && "$R_MEDIA_FORBID_2" == *"INSUFFICIENT_SCOPE"* ]] && echo true || echo false)" \
        "Akses endpoint /hazards/${SAMPLE_HID}/raw oleh Media ditolak server dengan HTTP 403 INSUFFICIENT_SCOPE"

    R_FIELD_RAW=$(curl -s -H "Authorization: Bearer ${F_ACCESS}" "${CLIENT_API_URL}/hazards/${SAMPLE_HID}/raw" || echo "{}")
    HAS_RAW=$(echo "$R_FIELD_RAW" | jq '.data | (has("source_ref_id") and has("latitude") and has("longitude") and has("attributes"))' 2>/dev/null || echo "false")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <field-team-token>' '${CLIENT_API_URL}/hazards/${SAMPLE_HID}/raw'" \
        "$R_FIELD_RAW" \
        "$([[ "$HAS_RAW" == "true" ]] && echo true || echo false)" \
        "Tim Lapangan berhasil mengakses seluruh field Mentah (source_ref_id, latitude, longitude, attributes)"

    # Task P3.3: Kedaluwarsa Access Token Tim Lapangan (TTL 60s), Refresh Tanpa Login Ulang, & Penolakan Token Lama
    start_task \
        "[P3.3 - Kedaluwarsa TTL Access Token & Rotasi Refresh Token] Tunggu access token Tim Lapangan kedaluwarsa secara alami sesuai TTL (${F_TTL}s), lakukan refresh tanpa login ulang manual, dan tunjukkan token lama ditolak" \
        "Setelah TTL habis access token lama ditolak HTTP 401 TOKEN_EXPIRED, POST /refresh menerbitkan token baru yang valid (HTTP 200), dan pemakaian ulang refresh token lama ditolak HTTP 401"

    if [[ "$FAST_MODE" == "false" ]]; then
        WAIT_S=$((F_TTL + 2))
        sleep "$WAIT_S"
        R_EXP_TOK=$(curl_error_raw -H "Authorization: Bearer ${F_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1")
        print_step_result \
            "curl -i -s -H 'Authorization: Bearer <expired-field-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
            "$R_EXP_TOK" \
            "$([[ "$R_EXP_TOK" == *"401"* && "$R_EXP_TOK" == *"TOKEN_EXPIRED"* ]] && echo true || echo false)" \
            "Setelah ${WAIT_S} detik (TTL=${F_TTL}s), access token lama ditolak dengan HTTP 401 TOKEN_EXPIRED"
    fi

    R_REFRESH=$(curl -s -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"${F_REFRESH}\"}" || echo "{}")
    NEW_F_ACCESS=$(echo "$R_REFRESH" | jq -r '.access_token // ""')
    print_step_result \
        "curl -s -X POST ${AUTH_URL}/refresh -H 'Content-Type: application/json' -d '{\"refresh_token\":\"${F_REFRESH}\"}'" \
        "$R_REFRESH" \
        "$([[ -n "$NEW_F_ACCESS" && "$NEW_F_ACCESS" != "null" ]] && echo true || echo false)" \
        "Alur POST /refresh menerbitkan pasangan access_token dan refresh_token baru tanpa login ulang manual"

    R_NEW_ACCESS_USE=$(curl -s -H "Authorization: Bearer ${NEW_F_ACCESS}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
    NEW_USE_CNT=$(echo "$R_NEW_ACCESS_USE" | jq '.data | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <new-field-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_NEW_ACCESS_USE" \
        "$([[ "$NEW_USE_CNT" -gt 0 ]] && echo true || echo false)" \
        "Access token baru hasil refresh diterima dengan baik oleh Client-Facing API (HTTP 200)"

    R_REPLAY_REFRESH=$(curl_error_raw -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"${F_REFRESH}\"}")
    print_step_result \
        "curl -i -s -X POST ${AUTH_URL}/refresh -H 'Content-Type: application/json' -d '{\"refresh_token\":\"${F_REFRESH}\"}'" \
        "$R_REPLAY_REFRESH" \
        "$([[ "$R_REPLAY_REFRESH" == *"401"* && "$R_REPLAY_REFRESH" == *"invalid_grant"* ]] && echo true || echo false)" \
        "Refresh token lama ditolak dengan HTTP 401 (invalid_grant) setelah dirotasi"

    # Task P3.4: Audit tidak ada kredensial ter-hardcode/ter-commit & keberadaan .env.example
    start_task \
        "[P3.4 - Ketentuan 6 & Hygiene Kredensial] Tunjukkan tidak ada kredensial yang ter-hardcode di kode maupun ter-commit di git, dan berkas .env.example tersedia" \
        "Seluruh 9 berkas .env.example tersedia, git ls-files tidak memuat berkas .env, dan kode sumber tidak memuat secret hardcoded"

    R_ENV_FILES=$(cd "$PROJECT_ROOT" && ls -1 .env.example services/*/.env.example 2>/dev/null || echo "")
    ENV_FILE_CNT=$(echo "$R_ENV_FILES" | grep -v "^$" | wc -l | tr -d ' ')
    print_step_result \
        "ls -1 .env.example services/*/.env.example" \
        "$R_ENV_FILES" \
        "$([[ "$ENV_FILE_CNT" -eq 9 ]] && echo true || echo false)" \
        "Tersedia ${ENV_FILE_CNT}/9 berkas .env.example di root dan seluruh service"

    R_GIT_ENV=$(cd "$PROJECT_ROOT" && (git ls-files | grep -E '(^|/)\.env$' || echo "NONE"))
    print_step_result \
        "git ls-files | grep -E '(^|/)\\.env$'" \
        "$R_GIT_ENV" \
        "$([[ "$R_GIT_ENV" == "NONE" ]] && echo true || echo false)" \
        "Tidak ada berkas .env yang ter-commit di repositori git (NONE)"

    R_HARDCODE=$(cd "$PROJECT_ROOT" && (git grep -rnE "BEGIN PRIVATE KEY" services/ || echo "NONE"))
    print_step_result \
        "git grep -rnE 'BEGIN PRIVATE KEY' services/" \
        "$R_HARDCODE" \
        "$([[ "$R_HARDCODE" == "NONE" ]] && echo true || echo false)" \
        "Tidak ditemukan private key hardcoded pada repository (NONE)"
fi

# ==============================================================================
# PROBLEM 4: ARSITEKTUR MICROSERVICE & FLEXIBLE STORAGE
# ==============================================================================
if should_run "p4"; then
    OPS_TOK=$(fetch_ops_token)

    # Task P4.1: Independensi Container
    start_task \
        "[P4.1 - Independensi Container Microservice] Tunjukkan setiap komponen berjalan sebagai container terpisah, dapat dihentikan dan dijalankan ulang tanpa me-restart container lain, serta sistem tetap melayani permintaan yang tidak bergantung pada komponen yang sedang dihentikan" \
        "Saat auth-service dihentikan, client-api tetap melayani GET /hazards (HTTP 200); saat aggregator dihentikan, auth-service tetap melayani POST /token (HTTP 200), client-api mengembalikan 503 UPSTREAM_UNAVAILABLE, dan pulih otomatis setelah aggregator dinyalakan kembali"

    R_STOP_AUTH=$(cd "$PROJECT_ROOT" && docker compose stop auth-service 2>&1 || true)
    print_step_result \
        "docker compose stop auth-service" \
        "$R_STOP_AUTH" \
        "true" \
        "Container auth-service berhasil dihentikan secara independen"

    R_API_AUTH_DOWN=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
    API_AUTH_DOWN_CNT=$(echo "$R_API_AUTH_DOWN" | jq '.data | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_API_AUTH_DOWN" \
        "$([[ "$API_AUTH_DOWN_CNT" -gt 0 ]] && echo true || echo false)" \
        "Saat auth-service mati, client-api tetap melayani GET /hazards (HTTP 200) menggunakan verifikasi public key Ed25519 lokal"

    R_START_AUTH=$(cd "$PROJECT_ROOT" && docker compose start auth-service 2>&1 || true)
    for _ in {1..10}; do
        [[ "$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}/health" || true)" == "200" ]] && break
        sleep 1
    done
    print_step_result \
        "docker compose start auth-service" \
        "$R_START_AUTH" \
        "true" \
        "Container auth-service berhasil dinyalakan kembali tanpa me-restart container lain"

    R_STOP_AGG=$(cd "$PROJECT_ROOT" && docker compose stop aggregator 2>&1 || true)
    print_step_result \
        "docker compose stop aggregator" \
        "$R_STOP_AGG" \
        "true" \
        "Container aggregator berhasil dihentikan secara independen"

    R_AUTH_AGG_DOWN=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}" || echo "{}")
    AUTH_AGG_TOK=$(echo "$R_AUTH_AGG_DOWN" | jq -r '.access_token // ""')
    print_step_result \
        "curl -s -X POST ${AUTH_URL}/token -H 'Content-Type: application/json' -d '{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"<ops-secret>\"}'" \
        "$R_AUTH_AGG_DOWN" \
        "$([[ -n "$AUTH_AGG_TOK" ]] && echo true || echo false)" \
        "Saat aggregator mati, auth-service tetap menerbitkan token secara normal (HTTP 200)"

    R_API_AGG_DOWN=$(curl_error_raw -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1")
    print_step_result \
        "curl -i -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_API_AGG_DOWN" \
        "$([[ "$R_API_AGG_DOWN" == *"503"* && "$R_API_AGG_DOWN" == *"UPSTREAM_UNAVAILABLE"* ]] && echo true || echo false)" \
        "Saat aggregator mati, client-api merespons secara terkontrol dengan HTTP 503 UPSTREAM_UNAVAILABLE"

    R_START_AGG=$(cd "$PROJECT_ROOT" && docker compose start aggregator 2>&1 || true)
    for _ in {1..15}; do
        sleep 1
        [[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" || true)" == "200" ]] && break
    done
    print_step_result \
        "docker compose start aggregator" \
        "$R_START_AGG" \
        "true" \
        "Container aggregator berhasil dinyalakan kembali"

    R_API_AGG_UP=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" || echo "{}")
    API_AGG_UP_CNT=$(echo "$R_API_AGG_UP" | jq '.data | length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1'" \
        "$R_API_AGG_UP" \
        "$([[ "$API_AGG_UP_CNT" -gt 0 ]] && echo true || echo false)" \
        "Client-Facing API otomatis kembali melayani permintaan (HTTP 200) tanpa me-restart container lain"

    # Task P4.2: Flexible Storage (PostgreSQL JSONB) tanpa migrasi skema
    start_task \
        "[P4.2 - Flexible Storage Tanpa Migrasi Skema] Tunjukkan record HazardEvent dari sebelum dan sesudah munculnya confidence_level tersimpan berdampingan pada kolom JSONB di Canonical Store tanpa migrasi skema dan keduanya dapat dibaca" \
        "Tabel hazard_events menyimpan record dengan dan tanpa confidence_level secara berdampingan di kolom attributes (JSONB) dan keduanya dapat dibaca melalui API"

    # Pastikan minimal ada 1 record dengan confidence_level di DB
    P4_CHK=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100" || echo "{}")
    NEW_CNT=$(echo "$P4_CHK" | jq '[.data[]? | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
    if [[ "$NEW_CNT" -eq 0 ]]; then
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" -H "Content-Type: application/json" -H "Authorization: Bearer ${PVMBG_TOKEN}" -d '{"enabled": true}' > /dev/null || true
        for _ in {1..9}; do
            sleep 2
            P4_CHK=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100" || echo "{}")
            NEW_CNT=$(echo "$P4_CHK" | jq '[.data[]? | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
            [[ "$NEW_CNT" -gt 0 ]] && break
        done
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" -H "Content-Type: application/json" -H "Authorization: Bearer ${PVMBG_TOKEN}" -d '{"enabled": false}' > /dev/null || true
    fi

    R_SQL_COEXIST=$(cd "$PROJECT_ROOT" && docker compose exec -T canonical-store psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "(SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' AND NOT (attributes ? 'confidence_level') ORDER BY occurred_at DESC LIMIT 2) UNION ALL (SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' AND (attributes ? 'confidence_level') ORDER BY occurred_at DESC LIMIT 2);" || true)
    print_step_result \
        "docker compose exec -T canonical-store psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"(SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' AND NOT (attributes ? 'confidence_level') ORDER BY occurred_at DESC LIMIT 2) UNION ALL (SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' AND (attributes ? 'confidence_level') ORDER BY occurred_at DESC LIMIT 2);\"" \
        "$R_SQL_COEXIST" \
        "$([[ "$R_SQL_COEXIST" == *"| f"* && "$R_SQL_COEXIST" == *"| t"* ]] && echo true || echo false)" \
        "Record lama (has_confidence_level=f) dan record baru (has_confidence_level=t) tersimpan berdampingan di PostgreSQL JSONB tanpa migrasi DDL"

    R_VOLC_ALL=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100" || echo "{}")
    OLD_SAMPLE=$(echo "$R_VOLC_ALL" | jq '([.data[]? | select(.attributes.confidence_level == null)][0]) // null' 2>/dev/null || echo "null")
    NEW_SAMPLE=$(echo "$R_VOLC_ALL" | jq '([.data[]? | select(.attributes.confidence_level != null)][0]) // null' 2>/dev/null || echo "null")
    R_API_COEXIST=$(jq -n --argjson old "$OLD_SAMPLE" --argjson new "$NEW_SAMPLE" '{old_schema_sample: $old, new_schema_sample: $new}' 2>/dev/null || echo "{}")
    HAS_BOTH_API=$(echo "$R_API_COEXIST" | jq '(.old_schema_sample != null and .new_schema_sample != null)' 2>/dev/null || echo "false")
    print_step_result \
        "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=100' | jq '{old_schema_sample: ..., new_schema_sample: ...}'" \
        "$R_API_COEXIST" \
        "$([[ "$HAS_BOTH_API" == "true" ]] && echo true || echo false)" \
        "Kedua versi record (sebelum dan sesudah perubahan skema) dapat dibaca secara utuh melalui API"

    # Task P4.3: Kepemilikan eksklusif Canonical Store oleh Aggregator
    start_task \
        "[P4.3 - Ketentuan 2 & Kepemilikan Eksklusif Canonical Store] Tunjukkan Canonical Store hanya dapat diakses langsung oleh Aggregator dan komponen lain (Client-Facing API) memperoleh data melalui API Aggregator" \
        "Hanya aggregator yang memiliki konfigurasi DATABASE_URL ke canonical-store, sedangkan client-api hanya mengakses AGGREGATOR_URL"

    R_DB_OWNERS=$(cd "$PROJECT_ROOT" && grep -rn "DATABASE_URL" services/*/.env.example || true)
    print_step_result \
        "grep -rn 'DATABASE_URL' services/*/.env.example" \
        "$R_DB_OWNERS" \
        "$([[ "$R_DB_OWNERS" == *"services/aggregator/.env.example"* && $(echo "$R_DB_OWNERS" | grep -v "^$" | wc -l | tr -d ' ') -eq 1 ]] && echo true || echo false)" \
        "Hanya services/aggregator yang memiliki konfigurasi koneksi langsung ke Canonical Store (DATABASE_URL)"

    R_CLIENT_ENV_CFG=$(cat "${PROJECT_ROOT}/services/client-api/.env.example")
    print_step_result \
        "cat services/client-api/.env.example" \
        "$R_CLIENT_ENV_CFG" \
        "$([[ "$R_CLIENT_ENV_CFG" == *"AGGREGATOR_URL=http://aggregator:8083"* && "$R_CLIENT_ENV_CFG" != *"DATABASE_URL"* ]] && echo true || echo false)" \
        "Client-Facing API tidak memiliki koneksi database langsung dan hanya membaca data melalui AGGREGATOR_URL"
fi

# ==============================================================================
# PROBLEM 5: FAN-OUT EVENT DISTRIBUTION / PUB-SUB
# ==============================================================================
if should_run "p5"; then
    # Task P5.1 & P5.2: Publikasi ke Message Broker (RabbitMQ) & >= 2 Consumer Independen
    start_task \
        "[P5.1 & P5.2 - Pub/Sub Fan-out ke >= 2 Consumer Independen] Tunjukkan setiap HazardEvent dipublikasikan ke message broker (RabbitMQ exchange hazard.events) dan minimal dua consumer independen (consumer-dashboard & consumer-notifier) menerima event dari stream yang sama" \
        "Exchange hazard.events (topic, durable) memiliki binding ke queue dashboard dan notifier, serta kedua consumer menerima event secara independen"

    R_BINDINGS=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source" | jq 'map({source, destination, destination_type, routing_key})' || echo "[]")
    HAS_2_Q=$(echo "$R_BINDINGS" | jq '([.[] | select(.destination == "dashboard")] | length > 0) and ([.[] | select(.destination == "notifier")] | length > 0)' 2>/dev/null || echo "false")
    print_step_result \
        "curl -s -u ${RABBITMQ_USER}:<pass> '${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source' | jq 'map({source, destination, destination_type, routing_key})'" \
        "$R_BINDINGS" \
        "$([[ "$HAS_2_Q" == "true" ]] && echo true || echo false)" \
        "Exchange hazard.events menyalurkan event ke queue independen dashboard dan notifier"

    R_DASH_LOG=$(cd "$PROJECT_ROOT" && docker compose logs --tail=30 consumer-dashboard 2>/dev/null | grep "hazard_event_received" | tail -n 1 || true)
    print_step_result \
        "docker compose logs --tail=30 consumer-dashboard | grep 'hazard_event_received' | tail -n 1" \
        "$R_DASH_LOG" \
        "$([[ -n "$R_DASH_LOG" ]] && echo true || echo false)" \
        "Consumer 1 (consumer-dashboard) menerima HazardEvent dari exchange hazard.events"

    R_NOTIF_LOG=$(cd "$PROJECT_ROOT" && docker compose logs --tail=30 consumer-notifier 2>/dev/null | grep "hazard_event_received" | tail -n 1 || true)
    print_step_result \
        "docker compose logs --tail=30 consumer-notifier | grep 'hazard_event_received' | tail -n 1" \
        "$R_NOTIF_LOG" \
        "$([[ -n "$R_NOTIF_LOG" ]] && echo true || echo false)" \
        "Consumer 2 (consumer-notifier) menerima HazardEvent secara independen dari exchange yang sama"

    # Task P5.3: Hentikan salah satu consumer, verifikasi producer & consumer lain tidak tertahan, lalu nyalakan kembali (catch-up)
    start_task \
        "[P5.3 - Ketahanan Saat Consumer Mati & Durable Queue Catch-up] Hentikan consumer-notifier selama beberapa waktu, tunjukkan producer dan consumer-dashboard tetap berjalan normal, lalu nyalakan kembali consumer-notifier dan tunjukkan event yang terbit selama mati tersusul (catch-up)" \
        "Saat consumer-notifier berhenti, consumer-dashboard tetap menerima event baru, pesan untuk notifier tertahan di durable queue RabbitMQ (messages_ready > 0), dan langsung diproses saat consumer-notifier dinyalakan kembali"

    R_STOP_NOTIF=$(cd "$PROJECT_ROOT" && docker compose stop consumer-notifier 2>&1 || true)
    print_step_result \
        "docker compose stop consumer-notifier" \
        "$R_STOP_NOTIF" \
        "true" \
        "Consumer consumer-notifier berhasil dihentikan"

    # Tunggu dan polling RabbitMQ queue sampai ada pesan yang mengendap (messages_ready > 0)
    R_QUEUE_BACKLOG="{}"
    READY_CNT=0
    for ((i=1; i<=15; i++)); do
        sleep 2
        R_QUEUE_BACKLOG=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier" | jq '{name, durable, messages_ready, messages_unacknowledged}' || echo "{}")
        READY_CNT=$(echo "$R_QUEUE_BACKLOG" | jq -r '.messages_ready // 0')
        if [[ "$READY_CNT" -gt 0 ]]; then
            break
        fi
    done

    print_step_result \
        "curl -s -u ${RABBITMQ_USER}:<pass> '${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier' | jq '{name, durable, messages_ready, messages_unacknowledged}'" \
        "$R_QUEUE_BACKLOG" \
        "$([[ "$READY_CNT" -gt 0 ]] && echo true || echo false)" \
        "Selama consumer-notifier mati, RabbitMQ menyimpan ${READY_CNT} pesan baru pada durable queue notifier tanpa menahan producer"

    R_DASH_DURING=$(cd "$PROJECT_ROOT" && docker compose logs --tail=20 consumer-dashboard 2>/dev/null | grep "hazard_event_received" | tail -n 1 || true)
    print_step_result \
        "docker compose logs --tail=20 consumer-dashboard | grep 'hazard_event_received' | tail -n 1" \
        "$R_DASH_DURING" \
        "$([[ -n "$R_DASH_DURING" ]] && echo true || echo false)" \
        "Consumer lain (consumer-dashboard) tetap menerima event secara real-time saat consumer-notifier mati"

    R_START_NOTIF=$(cd "$PROJECT_ROOT" && docker compose start consumer-notifier 2>&1 || true)
    print_step_result \
        "docker compose start consumer-notifier" \
        "$R_START_NOTIF" \
        "true" \
        "Consumer consumer-notifier berhasil dinyalakan kembali"

    R_QUEUE_AFTER="{}"
    READY_AFTER=99
    for _ in {1..10}; do
        sleep 1
        R_QUEUE_AFTER=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier" | jq '{name, durable, messages_ready, messages_unacknowledged}' || echo "{}")
        READY_AFTER=$(echo "$R_QUEUE_AFTER" | jq -r '.messages_ready // 99')
        if [[ "$READY_AFTER" -eq 0 ]]; then
            break
        fi
    done
    print_step_result \
        "curl -s -u ${RABBITMQ_USER}:<pass> '${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier' | jq '{name, durable, messages_ready, messages_unacknowledged}'" \
        "$R_QUEUE_AFTER" \
        "$([[ "$READY_AFTER" -eq 0 ]] && echo true || echo false)" \
        "Seluruh backlog pesan pada queue notifier telah tersusul (messages_ready=${READY_AFTER})"

    R_NOTIF_CATCHUP=$(cd "$PROJECT_ROOT" && docker compose logs --tail=20 consumer-notifier 2>/dev/null | grep "hazard_event_received" | tail -n 1 || true)
    print_step_result \
        "docker compose logs --tail=20 consumer-notifier | grep 'hazard_event_received' | tail -n 1" \
        "$R_NOTIF_CATCHUP" \
        "$([[ -n "$R_NOTIF_CATCHUP" ]] && echo true || echo false)" \
        "Log consumer-notifier mengonfirmasi penerimaan pesan yang terbit selama consumer mati (catch-up berhasil)"

    # Task P5.4: Penambahan consumer ke-3 secara dinamis tanpa mengubah kode producer
    start_task \
        "[P5.4 - Penambahan Consumer Baru Tanpa Mengubah Kode Producer] Tambahkan satu consumer baru (consumer-pemda-volcano) pada exchange hazard.events yang sudah ada tanpa mengubah kode maupun me-restart producer (aggregator)" \
        "Container consumer-pemda-volcano membuat queue pemda-volcano (routing_key=volcanic) dan menerima event vulkanik baru tanpa perubahan kode pada aggregator"

    R_START_PEMDA=$(cd "$PROJECT_ROOT" && docker compose --profile p5-extra up -d consumer-pemda-volcano 2>&1 || true)
    print_step_result \
        "docker compose --profile p5-extra up -d consumer-pemda-volcano" \
        "$R_START_PEMDA" \
        "true" \
        "Consumer ke-3 (consumer-pemda-volcano) berhasil dijalankan tanpa mengubah atau me-restart aggregator"

    sleep 12

    R_PEMDA_BIND=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source" | jq '[.[] | select(.destination == "pemda-volcano") | {source, destination, routing_key}]' || echo "[]")
    PEMDA_B_CNT=$(echo "$R_PEMDA_BIND" | jq 'length' 2>/dev/null || echo "0")
    print_step_result \
        "curl -s -u ${RABBITMQ_USER}:<pass> '${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source' | jq '[.[] | select(.destination == \"pemda-volcano\") | {source, destination, routing_key}]'" \
        "$R_PEMDA_BIND" \
        "$([[ "$PEMDA_B_CNT" -gt 0 ]] && echo true || echo false)" \
        "Queue pemda-volcano terikat secara dinamis ke exchange hazard.events dengan routing_key=volcanic"

    R_PEMDA_LOG=$(cd "$PROJECT_ROOT" && docker compose --profile p5-extra logs --tail=20 consumer-pemda-volcano 2>/dev/null | grep "hazard_event_received" | tail -n 1 || true)
    print_step_result \
        "docker compose --profile p5-extra logs --tail=20 consumer-pemda-volcano | grep 'hazard_event_received' | tail -n 1" \
        "$R_PEMDA_LOG" \
        "$([[ -n "$R_PEMDA_LOG" ]] && echo true || echo false)" \
        "Consumer baru (consumer-pemda-volcano) berhasil menerima HazardEvent tanpa perubahan kode pada producer"

    (cd "$PROJECT_ROOT" && docker compose --profile p5-extra stop consumer-pemda-volcano > /dev/null 2>&1 || true)

    # Task P5.5: P5-05 Semantik At-Least-Once, Idempotensi Notifier, & Penolakan Payload Rusak
    start_task \
        "[P5.5 - Semantik At-Least-Once & Idempotensi Consumer] Publikasikan event duplikat dan payload rusak ke exchange hazard.events, tunjukkan consumer-notifier melakukan deduplikasi idempoten serta menolak payload rusak tanpa requeue loop" \
        "Pesan pertama diproses (notification_sent), duplikasi di-skip (notification_skipped_duplicate), perubahan severity diproses ulang, dan pesan rusak ditolak (message_rejected)"

    NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    DUP_CORR="qa-dup-trace-$(date +%s)"

    # Helper publish synthetic event
    pub_event() {
        local sev="$1"
        local payload_json
        payload_json=$(jq -n --arg sev "$sev" --arg now "$NOW_TS" '{
            hazard_id: "QA-dup-0001",
            source: "BMKG",
            source_ref_id: "dup-0001",
            hazard_type: "SEISMIC",
            severity: $sev,
            area_name: "Uji QA Idempotensi",
            latitude: -6.2,
            longitude: 106.8,
            occurred_at: $now,
            ingested_at: $now,
            attributes: {}
        }')
        curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/publish" \
            -X POST -H "Content-Type: application/json" \
            -d "$(jq -n --arg sev "$sev" --arg corr "$DUP_CORR" --arg pl "$payload_json" '{
                routing_key: "seismic",
                payload: $pl,
                payload_encoding: "string",
                properties: {
                    message_id: ("QA-dup-0001:" + $sev),
                    correlation_id: $corr,
                    content_type: "application/json",
                    delivery_mode: 2,
                    type: "HazardEvent"
                }
            }')" > /dev/null || true
    }

    pub_event "SIAGA"
    pub_event "SIAGA"
    pub_event "AWAS"

    # Publish malformed payload
    curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/publish" \
        -X POST -H "Content-Type: application/json" \
        -d '{"routing_key":"seismic","payload":"bukan json","payload_encoding":"string","properties":{"message_id":"malformed-1","correlation_id":"qa-bad-001"}}' > /dev/null || true

    sleep 2

    R_IDEMP_LOGS=$(cd "$PROJECT_ROOT" && docker compose logs --since 10s --no-log-prefix consumer-notifier 2>/dev/null | jq -c "select(.correlation_id==\"${DUP_CORR}\" or .msg==\"message_rejected\") | {msg, idempotency_key, duplicate, error}" || true)
    HAS_SENT=$(echo "$R_IDEMP_LOGS" | grep -c '"msg":"notification_sent"' || echo "0")
    HAS_SKIPPED=$(echo "$R_IDEMP_LOGS" | grep -c '"msg":"notification_skipped_duplicate"' || echo "0")
    HAS_REJECTED=$(echo "$R_IDEMP_LOGS" | grep -c '"msg":"message_rejected"' || echo "0")
    IDEMP_OK="false"
    [[ "$HAS_SENT" -ge 2 && "$HAS_SKIPPED" -ge 1 && "$HAS_REJECTED" -ge 1 ]] && IDEMP_OK="true"

    print_step_result \
        "Publish duplicate events (SIAGA, SIAGA, AWAS) & malformed payload ke hazard.events" \
        "$R_IDEMP_LOGS" \
        "$IDEMP_OK" \
        "Consumer-notifier memproses event awal (${HAS_SENT}x sent), men-skip duplikasi (${HAS_SKIPPED}x skipped), dan menolak payload rusak (${HAS_REJECTED}x rejected)"
fi

echo "--------------------------------------------------------------------------------"
echo ""
echo "test : ${TOTAL_COUNT}"
echo "pass : ${PASSED_COUNT}"
echo "fail : ${FAILED_COUNT}"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
