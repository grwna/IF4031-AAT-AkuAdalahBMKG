#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# IF4031 MILESTONE 1 - END-TO-END (E2E) VERIFICATION SUITE
# ==============================================================================
# Menjalankan skrip verifikasi dan demo utama dengan format plain-text 5 baris:
#   task / expect / cmd / resp / res
#
# Penggunaan:
#   ./scripts/tests/test-e2e.sh [all|p0|p1|p2|p3|p4|p5] [--fast] [--step] [--no-save]
#   ./scripts/tests/test-e2e.sh --problem p1
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec "${PROJECT_ROOT}/scripts/demo/demo.sh" "$@"
