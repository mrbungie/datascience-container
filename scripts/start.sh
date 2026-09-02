#!/usr/bin/env bash
# Usage: start.sh [nginx|jupyter|sshd|cron|all]
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

seed_config

case "${1:-all}" in
    nginx)   start_nginx ;;
    jupyter) start_jupyter ;;
    sshd)    start_sshd ;;
    cron)    start_cron ;;
    all)     start_sshd; start_nginx; start_jupyter; start_cron ;;
    *) echo "usage: $0 [nginx|jupyter|sshd|cron|all]"; exit 1 ;;
esac
