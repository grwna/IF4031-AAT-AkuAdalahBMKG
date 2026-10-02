#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVICES=("bmkg-mock" "pvmbg-mock" "auth-service")

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run unit tests for services.

Options (mutually exclusive):
  -a             Test all services
  -s SERVICES    Test specific services (space-separated, quoted)

Examples:
  $(basename "$0") -a
  $(basename "$0") -s "bmkg-mock pvmbg-mock"
  $(basename "$0") -s "bmkg-mock"
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

TARGET_SERVICES=()
OPT_A=0
OPT_S=0

while getopts "as:" opt; do
    case "$opt" in
        a)
            OPT_A=1
            TARGET_SERVICES=("${SERVICES[@]}")
            ;;
        s)
            OPT_S=1
            IFS=' ' read -ra TARGET_SERVICES <<< "$OPTARG"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ $OPT_A -eq 1 ] && [ $OPT_S -eq 1 ]; then
    echo -e "${RED}Error: -a and -s are mutually exclusive.${NC}"
    usage
    exit 1
fi

if [ ${#TARGET_SERVICES[@]} -eq 0 ]; then
    usage
    exit 1
fi

FAILED=0

for svc in "${TARGET_SERVICES[@]}"; do
    SVC_DIR="services/${svc}"
    if [ ! -d "$SVC_DIR" ]; then
        echo -e "${RED}✗ ${svc}: directory not found${NC}"
        FAILED=1
        continue
    fi

    echo -e "${YELLOW}▶ Running tests for ${svc}...${NC}"
    if (cd "$SVC_DIR" && go test ./...); then
        echo -e "${GREEN}✓ ${svc}: all tests passed${NC}"
    else
        echo -e "${RED}✗ ${svc}: tests failed${NC}"
        FAILED=1
    fi
done

exit $FAILED