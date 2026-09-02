#!/usr/bin/env bash
# Usage: restart.sh [nginx|jupyter|all]
#
# For nginx this reloads config (conf.d additions, edits) with zero
# downtime. For jupyter it does a real stop+start since the server process
# itself has to pick up config changes — running kernels are lost, but
# nothing outside this container needs to restart and /workspace/config
# persists across it.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

case "${1:-all}" in
    nginx)
        reload_nginx
        ;;
    jupyter)
        stop_jupyter
        start_jupyter
        ;;
    all)
        reload_nginx
        stop_jupyter
        start_jupyter
        ;;
    *) echo "usage: $0 [nginx|jupyter|all]"; exit 1 ;;
esac
