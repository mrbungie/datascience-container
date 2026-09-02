#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

seed_config
configure_hf_token
start_nginx
start_jupyter

term_handler() {
    log "shutting down"
    stop_jupyter
    stop_nginx
    exit 0
}
trap term_handler SIGTERM SIGINT

log "container ready"
log "jupyter token: $(cat "${RUN_DIR}/jupyter.token" 2>/dev/null || echo '(set via JUPYTER_TOKEN)')"
log "extend nginx:   edit ${CONFIG_DIR}/nginx/conf.d/*.conf then run: /opt/scripts/restart.sh nginx"
log "restart jupyter: /opt/scripts/restart.sh jupyter"

if [ "$#" -gt 0 ]; then
    log "running: $*"
    "$@" &
else
    touch "${LOG_DIR}/nginx-error.log" "${LOG_DIR}/nginx-access.log" "${LOG_DIR}/jupyter.log"
    tail -F "${LOG_DIR}"/*.log &
fi

wait -n
