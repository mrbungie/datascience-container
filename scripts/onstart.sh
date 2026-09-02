#!/usr/bin/env bash
# Entry point for vast.ai's "onstart" script when using SSH launch mode.
#
# SSH launch mode injects vast.ai's own sshd setup (using $PUBLIC_KEY) and
# replaces this image's Docker ENTRYPOINT, so this script only starts what
# vast.ai doesn't manage for you: nginx, jupyter, cron (and, if
# IDLE_SHUTDOWN_ENABLE=1, the idle-shutdown watchdog via cron). It does NOT
# start our own sshd — vast.ai already has one bound to port 22.
#
# vast.ai template setup: launch mode "SSH", onstart = /opt/scripts/onstart.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

seed_config
sync_env_to_etc_environment
configure_hf_token
start_nginx
start_jupyter
start_cron

log "onstart done (sshd managed by vast.ai)"
log "jupyter token: $(cat "${RUN_DIR}/jupyter.token" 2>/dev/null || echo '(set via JUPYTER_TOKEN)')"
log "extend nginx:   edit ${CONFIG_DIR}/nginx/conf.d/*.conf then run: /opt/scripts/restart.sh nginx"
log "restart jupyter: /opt/scripts/restart.sh jupyter"
log "extend cron:    edit ${CONFIG_DIR}/cron/crontab then run: /opt/scripts/restart.sh cron"
