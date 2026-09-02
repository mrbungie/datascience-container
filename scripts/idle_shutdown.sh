#!/usr/bin/env bash
# Idle-shutdown watchdog, run periodically from cron when IDLE_SHUTDOWN_ENABLE=1.
#
# Checks CPU, RAM, and (if present) GPU utilization / VRAM against
# configurable thresholds. If ALL signals stay below their threshold for
# IDLE_GRACE_MINUTES straight, the machine is considered idle and
# IDLE_ACTION runs.
#
# Env vars (all optional, defaults shown):
#   IDLE_SHUTDOWN_ENABLE=0        master switch, set to 1 to enable the cron job
#   IDLE_CHECK_INTERVAL_MINUTES=5 how often this script runs (cron cadence)
#   IDLE_GRACE_MINUTES=30         consecutive idle time required before acting
#   IDLE_CPU_THRESHOLD_PCT=15     1-min load average, normalized by core count
#   IDLE_RAM_THRESHOLD_PCT=20     used = MemTotal - MemAvailable
#   IDLE_GPU_THRESHOLD_PCT=5      max utilization.gpu across GPUs (nvidia-smi)
#   IDLE_VRAM_THRESHOLD_PCT=10    max memory.used/memory.total across GPUs
#   IDLE_ACTION=exit               "exit" (stop the machine, see below) or
#                                  "notify" (log/webhook only, no shutdown)
#   IDLE_ACTION_CMD                if set, run this instead of the default
#                                  "exit" action
#
# The "exit" action picks the best available way to actually stop billing:
#   1. On vast.ai (CONTAINER_ID set) with the vastai CLI installed:
#      `vastai stop instance $CONTAINER_ID` — releases the GPU.
#   2. Otherwise: `kill -TERM 1`, which only works when this container's
#      own entrypoint (tini + entrypoint.sh) is PID 1 — i.e. plain `docker
#      run` or vast.ai's "Entrypoint" launch mode. It does nothing useful
#      under vast.ai's SSH/Jupyter launch modes, where PID 1 belongs to
#      vast.ai's own injected process, not to this image.
#   IDLE_WEBHOOK_URL              optional URL POSTed with a JSON payload
#                                 when idle is first detected and when action fires
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${DIR}/lib.sh"

IDLE_GRACE_MINUTES="${IDLE_GRACE_MINUTES:-30}"
IDLE_CPU_THRESHOLD_PCT="${IDLE_CPU_THRESHOLD_PCT:-15}"
IDLE_RAM_THRESHOLD_PCT="${IDLE_RAM_THRESHOLD_PCT:-20}"
IDLE_GPU_THRESHOLD_PCT="${IDLE_GPU_THRESHOLD_PCT:-5}"
IDLE_VRAM_THRESHOLD_PCT="${IDLE_VRAM_THRESHOLD_PCT:-10}"
IDLE_ACTION="${IDLE_ACTION:-exit}"

IDLE_SINCE_FILE="${RUN_DIR}/idle_since"
IDLE_NOTIFIED_FILE="${RUN_DIR}/idle_notified"

notify() {
    local msg="$1"
    log "idle-shutdown: ${msg}"
    if [ -n "${IDLE_WEBHOOK_URL:-}" ]; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":\"[$(hostname)] ${msg}\"}" \
            "${IDLE_WEBHOOK_URL}" >/dev/null 2>&1 \
            || log "idle-shutdown: webhook notify failed (non-fatal)"
    fi
}

cpu_pct() {
    local load1 nproc
    load1="$(cut -d' ' -f1 /proc/loadavg)"
    nproc="$(nproc)"
    awk -v l="$load1" -v n="$nproc" 'BEGIN { printf "%.0f", (l/n)*100 }'
}

ram_pct() {
    awk '
        /^MemTotal:/     { total=$2 }
        /^MemAvailable:/ { avail=$2 }
        END { printf "%.0f", ((total-avail)/total)*100 }
    ' /proc/meminfo
}

# Prints "<max_util_pct> <max_vram_pct>", or nothing if no GPU is visible.
gpu_stats() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | awk -F',' '
        {
            util=$1+0; used=$2+0; total=$3+0
            if (util > max_util) max_util = util
            if (total > 0) {
                vram = (used/total)*100
                if (vram > max_vram) max_vram = vram
            }
        }
        END {
            if (NR > 0) printf "%.0f %.0f", max_util, max_vram
        }
    '
}

cpu="$(cpu_pct)"
ram="$(ram_pct)"
read -r gpu vram <<< "$(gpu_stats)"

busy=0
reason=""
[ "${cpu}" -ge "${IDLE_CPU_THRESHOLD_PCT}" ] && { busy=1; reason="${reason} cpu=${cpu}%"; }
[ "${ram}" -ge "${IDLE_RAM_THRESHOLD_PCT}" ] && { busy=1; reason="${reason} ram=${ram}%"; }
if [ -n "${gpu:-}" ]; then
    [ "${gpu}" -ge "${IDLE_GPU_THRESHOLD_PCT}" ] && { busy=1; reason="${reason} gpu=${gpu}%"; }
    [ "${vram}" -ge "${IDLE_VRAM_THRESHOLD_PCT}" ] && { busy=1; reason="${reason} vram=${vram}%"; }
fi

if [ "${busy}" -eq 1 ]; then
    [ -f "${IDLE_SINCE_FILE}" ] && log "idle-shutdown: activity detected (${reason# }), resetting idle timer"
    rm -f "${IDLE_SINCE_FILE}" "${IDLE_NOTIFIED_FILE}"
    exit 0
fi

now="$(date +%s)"
if [ ! -f "${IDLE_SINCE_FILE}" ]; then
    echo "${now}" > "${IDLE_SINCE_FILE}"
    log "idle-shutdown: below thresholds (cpu=${cpu}% ram=${ram}% gpu=${gpu:-n/a}% vram=${vram:-n/a}%), starting idle timer"
    exit 0
fi

idle_since="$(cat "${IDLE_SINCE_FILE}")"
idle_minutes=$(( (now - idle_since) / 60 ))
log "idle-shutdown: idle for ${idle_minutes}m / ${IDLE_GRACE_MINUTES}m (cpu=${cpu}% ram=${ram}% gpu=${gpu:-n/a}% vram=${vram:-n/a}%)"

if [ "${idle_minutes}" -ge "${IDLE_GRACE_MINUTES}" ]; then
    if [ ! -f "${IDLE_NOTIFIED_FILE}" ]; then
        touch "${IDLE_NOTIFIED_FILE}"
        notify "idle for ${idle_minutes}m, action=${IDLE_ACTION}"
    fi
    case "${IDLE_ACTION}" in
        notify)
            ;;
        exit)
            if [ -n "${IDLE_ACTION_CMD:-}" ]; then
                log "idle-shutdown: running IDLE_ACTION_CMD"
                eval "${IDLE_ACTION_CMD}" || log "idle-shutdown: IDLE_ACTION_CMD failed"
            elif [ -n "${CONTAINER_ID:-}" ] && command -v vastai >/dev/null 2>&1; then
                log "idle-shutdown: stopping vast.ai instance ${CONTAINER_ID}"
                vastai stop instance "${CONTAINER_ID}" ${CONTAINER_API_KEY:+--api-key "${CONTAINER_API_KEY}"} \
                    || log "idle-shutdown: vastai stop instance failed"
            else
                log "idle-shutdown: no vastai CLI/CONTAINER_ID — shutting down this container (kill -TERM 1)"
                kill -TERM 1
            fi
            ;;
        *)
            log "idle-shutdown: unknown IDLE_ACTION='${IDLE_ACTION}', doing nothing"
            ;;
    esac
fi
