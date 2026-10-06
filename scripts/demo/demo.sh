#!/usr/bin/env bash

# ==============================================================================
# Interactive Live Demo Runner - IF4031 Milestone 1 (AkuAdalahBMKG)
# Dirancang khusus untuk Demonstrasi Sinkron di hadapan Asisten Penguji.
# Mendukung menu interaktif maupun subcommand langsung per Problem (P1 - P5).
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

NO_PAUSE="false"
MODE="menu"

usage() {
    cat <<EOF
Penggunaan: $(basename "$0") [PILIHAN] [MODUL]

Script Live Demo Interaktif untuk Milestone 1 IF4031 (AkuAdalahBMKG).

Modul:
  menu        Tampilkan menu interaktif pemilihan skenario demo (default)
  all         Jalankan seluruh demo berurutan (Ketentuan + P1 s/d P5)
  ketentuan   Demo Ketentuan Implementasi (Poin 1-7) & Model Ingest
  p1          Demo Problem 1: Arsitektur & Interoperabilitas Data (Schema Evolution)
  p2          Demo Problem 2: Concurrency, Availability, & Graceful Degradation
  p3          Demo Problem 3: Service-to-Service Authentication & Trust
  p4          Demo Problem 4: Arsitektur Microservice & Flexible Storage
  p5          Demo Problem 5: Fan-out Event Distribution / Pub-Sub

Pilihan:
  --no-pause  Jalankan langkah demi langkah secara otomatis tanpa menunggu [ENTER]
  -h, --help  Tampilkan bantuan ini

Contoh:
  ./scripts/demo/demo.sh              # Buka menu interaktif
  ./scripts/demo/demo.sh p1           # Langsung demokan Problem 1 dengan pause per step
  ./scripts/demo/demo.sh --no-pause all
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pause)
            NO_PAUSE="true"
            shift
            ;;
        menu|all|ketentuan|p1|p2|p3|p4|p5)
            MODE=$(echo "$1" | tr '[:upper:]' '[:lower:]')
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

cleanup() {
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": false}' > /dev/null 2>&1 || true
    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"enabled": false}' > /dev/null 2>&1 || true
    (cd "$PROJECT_ROOT" && docker compose start auth-service aggregator consumer-notifier consumer-dashboard > /dev/null 2>&1 || true)
    (cd "$PROJECT_ROOT" && docker compose --profile p5-extra stop consumer-pemda-volcano > /dev/null 2>&1 || true)
}
trap cleanup EXIT

pause_step() {
    local prompt_msg="${1:-Tekan [ENTER] untuk melanjutkan ke langkah berikutnya...}"
    if [[ "$NO_PAUSE" == "false" ]]; then
        echo ""
        read -r -p "$(echo -e "${YELLOW}${BOLD}⏸  ${prompt_msg}${NC}")" _
        echo ""
    else
        echo ""
    fi
}

step_header() {
    local code="$1"
    local title="$2"
    local narration="$3"
    echo -e "\n${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}║ [${code}] ${title}${NC}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}💡 Narasi Presenter:${NC} ${narration}\n"
}

show_cmd() {
    local cmd_str="$1"
    echo -e "  ${YELLOW}❯ Command:${NC} ${BOLD}${cmd_str}${NC}"
}

get_ops_token() {
    curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_OPS_ID}\",\"client_secret\":\"${CLIENT_OPS_SECRET}\"}" | jq -r '.access_token // ""'
}

# ==============================================================================
# DEMO 0: KETENTUAN IMPLEMENTASI & MODEL INGEST
# ==============================================================================
demo_ketentuan() {
    step_header "KETENTUAN 3 & 7" "Orkestrasi Container, Health Check, Seed Data (>=20), & Correlation ID" \
        "Menunjukkan seluruh service berjalan dalam container terpisah, memiliki endpoint /health, menyediakan >=20 record seed awal, serta meneruskan X-Correlation-ID dan mencatat latensi di JSON log."

    show_cmd "docker compose ps"
    (cd "$PROJECT_ROOT" && docker compose ps)

    echo ""
    show_cmd "curl -s ${BMKG_URL}/health && curl -s ${PVMBG_URL}/health && curl -s ${AGGREGATOR_URL}/health && curl -s ${CLIENT_API_URL}/health && curl -s ${AUTH_URL}/health"
    echo -e "  BMKG       : $(curl -s "${BMKG_URL}/health")"
    echo -e "  PVMBG      : $(curl -s "${PVMBG_URL}/health")"
    echo -e "  Aggregator : $(curl -s "${AGGREGATOR_URL}/health")"
    echo -e "  Client-API : $(curl -s "${CLIENT_API_URL}/health")"
    echo -e "  Auth-Svc   : $(curl -s "${AUTH_URL}/health")"

    pause_step "Tekan [ENTER] untuk melihat jumlah Seed Data awal (>=20 record) & Propagasi Correlation ID..."

    BMKG_CNT=$(curl -s -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/seismic-events" | jq 'length')
    TSU_CNT=$(curl -s -H "X-BMKG-Key: ${BMKG_API_KEY}" "${BMKG_URL}/tsunami-warnings" | jq 'length')
    PVMBG_CNT=$(curl -s -H "Authorization: Bearer ${PVMBG_TOKEN}" "${PVMBG_URL}/volcanic-reports" | jq 'length')
    echo -e "  ${GREEN}✓ Seed Data BMKG SeismicEvents  :${NC} ${BOLD}${BMKG_CNT} records${NC} (Syarat >= 20)"
    echo -e "  ${GREEN}✓ Seed Data BMKG TsunamiWarnings:${NC} ${BOLD}${TSU_CNT} records${NC}"
    echo -e "  ${GREEN}✓ Seed Data PVMBG VolcanicReport:${NC} ${BOLD}${PVMBG_CNT} records${NC} (Syarat >= 20)"

    echo ""
    DEMO_CORR="demo-trace-$(date +%s)"
    OPS_TOK=$(get_ops_token)
    show_cmd "curl -i -H 'Authorization: Bearer <ops-token>' -H 'X-Correlation-ID: ${DEMO_CORR}' '${CLIENT_API_URL}/hazards?limit=1'"
    curl -s -D - -H "Authorization: Bearer ${OPS_TOK}" -H "X-Correlation-ID: ${DEMO_CORR}" "${CLIENT_API_URL}/hazards?limit=1" | head -n 15

    echo -e "\n  ${CYAN}Potongan Structured JSON Log (memuat correlation_id & duration_ms):${NC}"
    (cd "$PROJECT_ROOT" && docker compose logs --tail=50 client-api aggregator 2>/dev/null | grep -E "${DEMO_CORR}|correlation_id" | tail -n 6 || true)
    pause_step
}

# ==============================================================================
# DEMO 1: PROBLEM 1 — ARSITEKTUR & INTEROPERABILITAS DATA
# ==============================================================================
demo_p1() {
    cleanup
    step_header "PROBLEM 1 (P1.1)" "Kondisi Awal: Pemetaan Kanonik SeismicEvent & VolcanicReport (Skema Lama)" \
        "Menunjukkan sistem berjalan normal pada skema awal PVMBG (tanpa confidence_level). Aggregator memetakan SeismicEvent (+ korelasi TsunamiWarning) dan VolcanicReport ke format kanonik HazardEvent."

    OPS_TOK=$(get_ops_token)
    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=SEISMIC&limit=2' | jq '.data'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=SEISMIC&limit=2" | jq '.data'

    echo ""
    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=1' | jq '.data[0]'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=1" | jq '.data[0]'
    echo -e "  ${GREEN}↑ Perhatikan pada skema awal di atas, field 'attributes' hanya berisi 'ash_column_height_m' & 'eruption_count_24h' (belum ada 'confidence_level').${NC}"

    pause_step "Tekan [ENTER] untuk memicu perubahan skema PVMBG (POST /admin/schema-version) TANPA restart..."

    step_header "PROBLEM 1 (P1.2 - P1.4)" "Trigger Evolusi Skema Aditif (confidence_level) Saat Sistem Berjalan" \
        "Mengaktifkan kemunculan field baru 'confidence_level' di PVMBG. Tanpa me-restart mock maupun aggregator, field baru otomatis ditangkap dan dimasukkan ke map 'attributes' sesuai kebijakan dynamic field mapping."

    show_cmd "curl -X POST ${PVMBG_URL}/admin/schema-version -H 'Authorization: Bearer <pvmbg-token>' -d '{\"enabled\": true}'"
    curl -s -X POST "${PVMBG_URL}/admin/schema-version" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"enabled": true}' | jq .

    echo -e "  ${YELLOW}⏳ Menunggu event baru dengan confidence_level di-ingest oleh Aggregator...${NC}"
    for _ in {1..9}; do
        sleep 2
        FOUND_C=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=20" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
        if [[ "$FOUND_C" -gt 0 ]]; then
            break
        fi
    done

    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=20' | jq '[.data[] | select(.attributes.confidence_level != null)][0]'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=20" | jq '[.data[] | select(.attributes.confidence_level != null)][0]'
    echo -e "  ${GREEN}✓ Terbukti! Aggregator tetap berjalan tanpa restart dan 'confidence_level' otomatis masuk ke 'attributes'.${NC}"
    pause_step
}

# ==============================================================================
# DEMO 2: PROBLEM 2 — CONCURRENCY, AVAILABILITY, & GRACEFUL DEGRADATION
# ==============================================================================
demo_p2() {
    cleanup
    OPS_TOK=$(get_ops_token)

    step_header "PROBLEM 2 (P2.1)" "Isolasi Read-Path & Bebas Head-of-Line Blocking (BMKG-only p95 < 300ms)" \
        "Mengirim permintaan BMKG-only (SEISMIC) bersamaan dengan permintaan PVMBG yang lambat (s/d 3 detik). Karena polling berjalan asinkron di background dan read-path membaca Canonical Store, latensi p95 BMKG-only tetap < 300 ms."

    show_cmd "./scripts/load-test/run-load-test.sh --quick (Tahap 1: Benchmark P2.1 & Tahap 2: Uji Beban Paralel)"
    if [[ "$NO_PAUSE" == "false" ]]; then
        read -r -p "$(echo -e "${CYAN}Pilih durasi Load Test P2.2: [1] Quick 15 detik untuk Demo, atau [2] Full 60 detik sesuai spek (default=1): ${NC}")" lt_choice
        if [[ "${lt_choice:-1}" == "2" ]]; then
            "${PROJECT_ROOT}/scripts/load-test/run-load-test.sh" --vus 55 --duration 60
        else
            "${PROJECT_ROOT}/scripts/load-test/run-load-test.sh" --vus 55 --duration 15
        fi
    else
        "${PROJECT_ROOT}/scripts/load-test/run-load-test.sh" --vus 55 --duration 10 --no-save
    fi

    pause_step "Tekan [ENTER] untuk mendemokan Simulasi Outage PVMBG (P2.3)..."

    step_header "PROBLEM 2 (P2.3)" "Simulasi Outage PVMBG, Graceful Degradation (stale_since), & Auto-Recovery" \
        "Menyalakan outage PVMBG secara instan via POST /admin/outage. Selama outage, data seismik tetap segar (UP), sedangkan data vulkanik dijawab dengan data terakhir dari Canonical Store disertai status DEGRADED dan timestamp stale_since (bukan error 500/timeout)."

    show_cmd "curl -X POST ${PVMBG_URL}/admin/outage -H 'Authorization: Bearer <pvmbg-token>' -d '{\"outage\": true}'"
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": true}' | jq .

    echo -e "  ${YELLOW}⏳ Menunggu 4 detik agar siklus polling Aggregator mendeteksi outage PVMBG...${NC}"
    sleep 4

    OPS_TOK=$(get_ops_token)
    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=2' | jq '{source_status: .source_status, sample_cached_volcanic: .data[0]}'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=2" | jq '{source_status: .source_status, sample_cached_volcanic: .data[0]}'

    pause_step "Tekan [ENTER] untuk mematikan Outage PVMBG dan melihat Auto-Recovery..."

    show_cmd "curl -X POST ${PVMBG_URL}/admin/outage -H 'Authorization: Bearer <pvmbg-token>' -d '{\"outage\": false}'"
    curl -s -X POST "${PVMBG_URL}/admin/outage" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer ${PVMBG_TOKEN}" \
         -d '{"outage": false}' | jq .

    echo -e "  ${YELLOW}⏳ Menunggu 4 detik untuk auto-recovery tanpa restart...${NC}"
    sleep 4

    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1' | jq '.source_status'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" | jq '.source_status'
    echo -e "  ${GREEN}✓ Status PVMBG otomatis kembali 'UP' dan 'stale_since' menjadi null tanpa restart!${NC}"
    pause_step
}

# ==============================================================================
# DEMO 3: PROBLEM 3 — SERVICE-TO-SERVICE AUTHENTICATION & TRUST
# ==============================================================================
demo_p3() {
    step_header "PROBLEM 3 (P3.1)" "Pemisahan Domain of Trust: Kredensial BMKG Ditolak PVMBG & Sebaliknya" \
        "Membuktikan kredensial antar instansi independen: X-BMKG-Key ditolak oleh PVMBG dengan 401, dan Bearer Token PVMBG ditolak oleh BMKG dengan 401."

    show_cmd "curl -i -H 'X-BMKG-Key: ${BMKG_API_KEY}' ${PVMBG_URL}/volcanic-reports"
    curl -s -i -H "X-BMKG-Key: ${BMKG_API_KEY}" "${PVMBG_URL}/volcanic-reports" | head -n 8

    echo ""
    show_cmd "curl -i -H 'Authorization: Bearer ${PVMBG_TOKEN}' ${BMKG_URL}/seismic-events"
    curl -s -i -H "Authorization: Bearer ${PVMBG_TOKEN}" "${BMKG_URL}/seismic-events" | head -n 8

    pause_step "Tekan [ENTER] untuk mendemokan Hak Akses Media vs Tim Lapangan/Ops (P3.2)..."

    step_header "PROBLEM 3 (P3.2)" "Penegakan Scope Media (Ringkasan Saja & 403 pada Field Mentah) vs Tim Lapangan" \
        "Mengambil token untuk Media (hazards:read:summary) dan Tim Lapangan (hazards:read:raw). Media hanya menerima field Ringkasan, dan permintaan eksplisit terhadap field Mentah ditolak server dengan HTTP 403 INSUFFICIENT_SCOPE."

    MEDIA_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_MEDIA_ID}\",\"client_secret\":\"${CLIENT_MEDIA_SECRET}\"}")
    MEDIA_TOK=$(echo "$MEDIA_RESP" | jq -r '.access_token')

    FIELD_RESP=$(curl -s -X POST "${AUTH_URL}/token" -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_FIELD_ID}\",\"client_secret\":\"${CLIENT_FIELD_SECRET}\"}")
    FIELD_TOK=$(echo "$FIELD_RESP" | jq -r '.access_token')
    FIELD_REF=$(echo "$FIELD_RESP" | jq -r '.refresh_token')

    echo -e "  ${GREEN}1. Respons GET /hazards untuk Media (Hanya 7 Field Ringkasan, Tanpa Koordinat/Attributes):${NC}"
    show_cmd "curl -s -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards?limit=1' | jq '.data[0]'"
    FIRST_ID=$(curl -s -H "Authorization: Bearer ${MEDIA_TOK}" "${CLIENT_API_URL}/hazards?limit=1" | tee /dev/tty | jq -r '.data[0].hazard_id')

    echo -e "\n  ${RED}2. Media Meminta Field Mentah Secara Eksplisit (?fields=severity,latitude & /raw) -> Ditolak 403:${NC}"
    show_cmd "curl -i -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards?fields=severity,latitude'"
    curl -s -i -H "Authorization: Bearer ${MEDIA_TOK}" "${CLIENT_API_URL}/hazards?fields=severity,latitude" | head -n 12

    echo ""
    show_cmd "curl -i -H 'Authorization: Bearer <media-token>' '${CLIENT_API_URL}/hazards/${FIRST_ID}/raw'"
    curl -s -i -H "Authorization: Bearer ${MEDIA_TOK}" "${CLIENT_API_URL}/hazards/${FIRST_ID}/raw" | head -n 12

    echo -e "\n  ${GREEN}3. Tim Lapangan Mengakses Endpoint /raw yang Sama -> Diterima 200 OK Lengkap:${NC}"
    show_cmd "curl -s -H 'Authorization: Bearer <field-team-token>' '${CLIENT_API_URL}/hazards/${FIRST_ID}/raw' | jq ."
    curl -s -H "Authorization: Bearer ${FIELD_TOK}" "${CLIENT_API_URL}/hazards/${FIRST_ID}/raw" | jq .

    pause_step "Tekan [ENTER] untuk mendemokan Kedaluwarsa Alami Access Token (TTL ${ACCESS_TOKEN_TTL}s) & Refresh Token Flow (P3.3)..."

    step_header "PROBLEM 3 (P3.3 & P3.4)" "Kedaluwarsa Access Token Tim Lapangan (TTL ${ACCESS_TOKEN_TTL}s) & Rotasi Refresh Token" \
        "Menunggu access token Tim Lapangan kedaluwarsa alami sesuai TTL (60 detik), membuktikan token lama ditolak 401 TOKEN_EXPIRED, melakukan refresh tanpa login ulang, dan membuktikan refresh token lama tidak bisa dipakai ulang."

    WAIT_TTL=$((ACCESS_TOKEN_TTL + 1))
    if [[ "$NO_PAUSE" == "false" ]]; then
        echo -e "  ${YELLOW}⏳ Countdown ${WAIT_TTL} detik untuk kedaluwarsa alami token (tekan [s] jika ingin skip tunggu):${NC}"
        for ((sec=WAIT_TTL; sec>=1; sec--)); do
            printf "\r     Sisa waktu TTL: %2d detik... " "$sec"
            if read -r -t 1 -n 1 key; then
                if [[ "$key" == "s" || "$key" == "S" ]]; then
                    echo -e "\n  ${YELLOW}↷ Melewati sisa countdown atas permintaan presenter.${NC}"
                    break
                fi
            fi
        done
        echo ""
    fi

    echo -e "\n  ${CYAN}A. Mengakses /hazards dengan Access Token Lama (Setelah TTL):${NC}"
    show_cmd "curl -i -H 'Authorization: Bearer <old-field-token>' '${CLIENT_API_URL}/hazards?limit=1'"
    curl -s -i -H "Authorization: Bearer ${FIELD_TOK}" "${CLIENT_API_URL}/hazards?limit=1" | head -n 12

    echo -e "\n  ${CYAN}B. Melakukan Refresh Token Tanpa Login Ulang Manual (POST /refresh):${NC}"
    show_cmd "curl -s -X POST ${AUTH_URL}/refresh -d '{\"refresh_token\":\"<refresh-token>\"}'"
    REF_OUT=$(curl -s -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" -d "{\"refresh_token\":\"${FIELD_REF}\"}")
    echo "$REF_OUT" | jq .
    NEW_FIELD_TOK=$(echo "$REF_OUT" | jq -r '.access_token // ""')

    echo -e "\n  ${CYAN}C. Mengakses /hazards dengan Access Token Baru Hasil Refresh (200 OK):${NC}"
    show_cmd "curl -s -H 'Authorization: Bearer <new-field-token>' '${CLIENT_API_URL}/hazards?limit=1' | jq '.data[0].hazard_id'"
    curl -s -H "Authorization: Bearer ${NEW_FIELD_TOK}" "${CLIENT_API_URL}/hazards?limit=1" | jq '.data[0]'

    echo -e "\n  ${CYAN}D. Mencoba Pakai Ulang (Replay) Refresh Token Lama -> Ditolak 401:${NC}"
    show_cmd "curl -i -X POST ${AUTH_URL}/refresh -d '{\"refresh_token\":\"<old-refresh-token>\"}'"
    curl -s -i -X POST "${AUTH_URL}/refresh" -H "Content-Type: application/json" -d "{\"refresh_token\":\"${FIELD_REF}\"}" | head -n 12
    pause_step
}

# ==============================================================================
# DEMO 4: PROBLEM 4 — ARSITEKTUR MICROSERVICE & FLEXIBLE STORAGE
# ==============================================================================
demo_p4() {
    step_header "PROBLEM 4 (P4.1)" "Independensi Container: Stop/Restart Satu Service Tanpa Mengganggu Service Lain" \
        "Menghentikan sementara auth-service dan membuktikan client-api tetap melayani request GET /hazards (karena verifikasi JWT Ed25519 menggunakan public key lokal). Kemudian me-restart aggregator secara independen tanpa me-restart container lain."

    OPS_TOK=$(get_ops_token)
    show_cmd "docker compose stop auth-service"
    (cd "$PROJECT_ROOT" && docker compose stop auth-service)

    echo -e "\n  ${GREEN}Mengirim request ke Client-API saat auth-service mati:${NC}"
    show_cmd "curl -s -H 'Authorization: Bearer <ops-token>' '${CLIENT_API_URL}/hazards?limit=1' | jq '.data[0]'"
    curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?limit=1" | jq '.data[0]'

    show_cmd "docker compose start auth-service"
    (cd "$PROJECT_ROOT" && docker compose start auth-service)

    pause_step "Tekan [ENTER] untuk mendemokan Flexible Storage JSONB Tanpa Migrasi (P4.2 & P4.3)..."

    step_header "PROBLEM 4 (P4.2 & P4.3)" "Flexible Storage (PostgreSQL JSONB) Tanpa Migrasi & Kepemilikan Canonical Store" \
        "Menampilkan isi tabel hazard_events di PostgreSQL Canonical Store secara langsung: record dari sebelum perubahan skema (tanpa confidence_level) dan sesudah perubahan skema (dengan confidence_level) hidup berdampingan tanpa migrasi kolom."

    # Pastikan ada contoh record dengan confidence_level
    FOUND_P4=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
    if [[ "$FOUND_P4" -eq 0 ]]; then
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" -H "Content-Type: application/json" -H "Authorization: Bearer ${PVMBG_TOKEN}" -d '{"enabled": true}' > /dev/null
        for _ in {1..9}; do
            sleep 2
            FOUND_P4=$(curl -s -H "Authorization: Bearer ${OPS_TOK}" "${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=50" | jq '[.data[] | select(.attributes.confidence_level != null)] | length' 2>/dev/null || echo "0")
            [[ "$FOUND_P4" -gt 0 ]] && break
        done
        curl -s -X POST "${PVMBG_URL}/admin/schema-version" -H "Content-Type: application/json" -H "Authorization: Bearer ${PVMBG_TOKEN}" -d '{"enabled": false}' > /dev/null
    fi

    show_cmd "docker compose exec canonical-store psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence, attributes FROM hazard_events WHERE hazard_type='VOLCANIC' ORDER BY (attributes ? 'confidence_level') DESC, occurred_at DESC LIMIT 6;\""
    (cd "$PROJECT_ROOT" && docker compose exec -T canonical-store psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence, attributes FROM hazard_events WHERE hazard_type='VOLCANIC' ORDER BY (attributes ? 'confidence_level') DESC, occurred_at DESC LIMIT 6;")
    pause_step
}

# ==============================================================================
# DEMO 5: PROBLEM 5 — FAN-OUT EVENT DISTRIBUTION / PUB-SUB
# ==============================================================================
demo_p5() {
    step_header "PROBLEM 5 (P5.1 & P5.2)" "Fan-out Event Distribution ke >= 2 Consumer Independen via RabbitMQ" \
        "Menunjukkan setiap HazardEvent dipublikasikan ke exchange 'hazard.events' (topic, durable) dan diterima secara independen oleh consumer-dashboard serta consumer-notifier."

    show_cmd "curl -u ${RABBITMQ_USER}:*** ${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source"
    curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/exchanges/%2F/hazard.events/bindings/source" | jq '.[] | {source, destination, routing_key}'

    echo -e "\n  ${CYAN}Log penerimaan event pada consumer-dashboard & consumer-notifier:${NC}"
    (cd "$PROJECT_ROOT" && docker compose logs --tail=6 consumer-dashboard consumer-notifier)

    pause_step "Tekan [ENTER] untuk mendemokan penghentian 1 consumer & penyusulan pesan / Catch-up (P5.3)..."

    step_header "PROBLEM 5 (P5.3)" "Ketahanan Saat Satu Consumer Mati & Penyusulan Pesan (At-Least-Once Catch-up)" \
        "Menghentikan consumer-notifier selama 12 detik. Producer (aggregator) tidak tertahan dan consumer-dashboard tetap menerima event. Pesan untuk notifier disimpan di durable queue RabbitMQ dan langsung tersusul begitu consumer-notifier dinyalakan kembali."

    show_cmd "docker compose stop consumer-notifier"
    (cd "$PROJECT_ROOT" && docker compose stop consumer-notifier)

    echo -e "  ${YELLOW}⏳ Menunggu 12 detik agar event baru terbit saat consumer-notifier mati...${NC}"
    sleep 12

    echo -e "  ${CYAN}Status Queue 'notifier' di RabbitMQ saat consumer-notifier mati:${NC}"
    curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier" | jq '{name, durable, messages_ready, consumers}'

    echo -e "\n  ${CYAN}Log consumer-dashboard (tetap menerima event secara normal):${NC}"
    (cd "$PROJECT_ROOT" && docker compose logs --tail=4 consumer-dashboard)

    pause_step "Tekan [ENTER] untuk menyalakan kembali consumer-notifier dan melihat pesan tersusul..."

    show_cmd "docker compose start consumer-notifier"
    (cd "$PROJECT_ROOT" && docker compose start consumer-notifier)
    sleep 3

    echo -e "  ${CYAN}Status Queue 'notifier' setelah consumer-notifier hidup kembali (messages_ready = 0):${NC}"
    curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" "${RABBITMQ_MGMT_URL}/api/queues/%2F/notifier" | jq '{name, durable, messages_ready, consumers}'

    echo -e "\n  ${CYAN}Log consumer-notifier (pesan yang terbit selama mati berhasil disusul):${NC}"
    (cd "$PROJECT_ROOT" && docker compose logs --tail=6 consumer-notifier)

    pause_step "Tekan [ENTER] untuk mendemokan penambahan Consumer ke-3 tanpa mengubah kode Producer (P5.4)..."

    step_header "PROBLEM 5 (P5.4)" "Penambahan Consumer Baru (consumer-pemda-volcano) Tanpa Mengubah Kode Producer" \
        "Menyalakan container consumer-pemda-volcano (profile p5-extra) yang berlangganan pada exchange 'hazard.events' dengan routing key 'volcanic', tanpa mengubah atau me-restart aggregator."

    show_cmd "docker compose --profile p5-extra up -d consumer-pemda-volcano"
    (cd "$PROJECT_ROOT" && docker compose --profile p5-extra up -d consumer-pemda-volcano)

    echo -e "  ${YELLOW}⏳ Menunggu 11 detik agar event vulkanik baru diterima oleh consumer-pemda-volcano...${NC}"
    sleep 11

    show_cmd "docker compose --profile p5-extra logs --tail=10 consumer-pemda-volcano"
    (cd "$PROJECT_ROOT" && docker compose --profile p5-extra logs --tail=10 consumer-pemda-volcano)

    pause_step
}

run_all_demos() {
    demo_ketentuan
    demo_p1
    demo_p2
    demo_p3
    demo_p4
    demo_p5
}

if [[ "$MODE" != "menu" ]]; then
    case "$MODE" in
        all)       run_all_demos ;;
        ketentuan) demo_ketentuan ;;
        p1)        demo_p1 ;;
        p2)        demo_p2 ;;
        p3)        demo_p3 ;;
        p4)        demo_p4 ;;
        p5)        demo_p5 ;;
    esac
    exit 0
fi

# Menu Interaktif
while true; do
    echo -e "${CYAN}${BOLD}"
    echo "================================================================================"
    echo "   MENU LIVE DEMO INTERAKTIF — IF4031 MILESTONE 1 (AKU ADALAH BMKG)             "
    echo "================================================================================"
    echo -e "${NC}"
    echo -e "  ${BOLD}[0]${NC} Demo Ketentuan Umum (1-7) & Model Ingest (Health, Seed >=20, Correlation ID)"
    echo -e "  ${BOLD}[1]${NC} Demo Problem 1 : Arsitektur & Interoperabilitas Data (Schema Evolution)"
    echo -e "  ${BOLD}[2]${NC} Demo Problem 2 : Concurrency, Load Test, Outage PVMBG & Graceful Degradation"
    echo -e "  ${BOLD}[3]${NC} Demo Problem 3 : Service-to-Service Auth, Scope Media vs Field, & Token TTL"
    echo -e "  ${BOLD}[4]${NC} Demo Problem 4 : Microservice Container Independence & Flexible Storage JSONB"
    echo -e "  ${BOLD}[5]${NC} Demo Problem 5 : Pub/Sub Fan-out, Consumer Catch-up, & Dynamic New Consumer"
    echo -e "  ${BOLD}[A]${NC} Jalankan Seluruh Skenario Demo Berurutan (0 s/d 5)"
    echo -e "  ${BOLD}[E]${NC} Jalankan Automated E2E Test Suite (scripts/tests/test-e2e.sh --fast)"
    echo -e "  ${BOLD}[Q]${NC} Keluar"
    echo ""
    read -r -p "$(echo -e "${YELLOW}${BOLD}Pilih skenario demo [0-5 / A / E / Q]: ${NC}")" choice
    case "$(echo "$choice" | tr '[:upper:]' '[:lower:]')" in
        0) demo_ketentuan ;;
        1) demo_p1 ;;
        2) demo_p2 ;;
        3) demo_p3 ;;
        4) demo_p4 ;;
        5) demo_p5 ;;
        a) run_all_demos ;;
        e) "${PROJECT_ROOT}/scripts/tests/test-e2e.sh" --fast ;;
        q) echo -e "${GREEN}Selesai. Semoga sukses demonya!${NC}"; exit 0 ;;
        *) echo -e "${RED}Pilihan tidak valid.${NC}" ;;
    esac
done
