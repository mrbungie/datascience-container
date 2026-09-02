#!/usr/bin/env bash
# Usage: stop.sh [nginx|jupyter|sshd|all]
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

case "${1:-all}" in
    nginx)   stop_nginx ;;
    jupyter) stop_jupyter ;;
    sshd)    stop_sshd ;;
    all)     stop_jupyter; stop_nginx; stop_sshd ;;
    *) echo "usage: $0 [nginx|jupyter|sshd|all]"; exit 1 ;;
esac
