#!/usr/bin/env bash
# Usage: start.sh [nginx|jupyter|all]
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

seed_config

case "${1:-all}" in
    nginx)   start_nginx ;;
    jupyter) start_jupyter ;;
    all)     start_nginx; start_jupyter ;;
    *) echo "usage: $0 [nginx|jupyter|all]"; exit 1 ;;
esac
