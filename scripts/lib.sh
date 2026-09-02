#!/usr/bin/env bash
# Shared paths/helpers sourced by every script in this directory.
set -euo pipefail

export WORKSPACE="${WORKSPACE:-/workspace}"
export CONFIG_DIR="${WORKSPACE}/config"
export LOG_DIR="${WORKSPACE}/logs"
export RUN_DIR="${WORKSPACE}/run"
export JUPYTER_ENV=/opt/venvs/jupyter

NGINX_PID_FILE="${RUN_DIR}/nginx.pid"
JUPYTER_PID_FILE="${RUN_DIR}/jupyter.pid"
SSHD_PID_FILE="${RUN_DIR}/sshd.pid"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

seed_config() {
    mkdir -p "${LOG_DIR}" "${RUN_DIR}"
    if [ ! -d "${CONFIG_DIR}" ]; then
        log "first boot: seeding ${CONFIG_DIR} from image defaults"
        mkdir -p "${CONFIG_DIR}"
        cp -r /opt/defaults/config/. "${CONFIG_DIR}/"
    fi
}

pid_alive() {
    local pidfile=$1
    [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

configure_basic_auth() {
    local nginx_cfg="${CONFIG_DIR}/nginx"
    mkdir -p "${nginx_cfg}"
    if [ -n "${BASIC_AUTH_PASSWORD:-}" ]; then
        local user="${BASIC_AUTH_USER:-vast}"
        log "HTTP basic auth enabled on nginx (user: ${user})"
        printf '%s:%s\n' "${user}" "$(openssl passwd -apr1 "${BASIC_AUTH_PASSWORD}")" \
            > "${nginx_cfg}/.htpasswd"
        cat > "${nginx_cfg}/auth.conf" <<EOF
auth_basic "restricted";
auth_basic_user_file ${nginx_cfg}/.htpasswd;
EOF
    else
        log "BASIC_AUTH_PASSWORD not set — nginx has no basic auth (Jupyter's own token is still required)"
        : > "${nginx_cfg}/auth.conf"
    fi
}

start_nginx() {
    configure_basic_auth
    if pid_alive "${NGINX_PID_FILE}"; then
        log "nginx already running (pid $(cat "${NGINX_PID_FILE}"))"
        return 0
    fi
    log "starting nginx"
    nginx -c "${CONFIG_DIR}/nginx/nginx.conf"
}

reload_nginx() {
    configure_basic_auth
    if pid_alive "${NGINX_PID_FILE}"; then
        log "reloading nginx config (no downtime)"
        nginx -c "${CONFIG_DIR}/nginx/nginx.conf" -s reload
    else
        start_nginx
    fi
}

stop_nginx() {
    if pid_alive "${NGINX_PID_FILE}"; then
        log "stopping nginx"
        nginx -c "${CONFIG_DIR}/nginx/nginx.conf" -s quit || true
        for _ in $(seq 1 20); do
            pid_alive "${NGINX_PID_FILE}" || break
            sleep 0.2
        done
    fi
}

start_jupyter() {
    if pid_alive "${JUPYTER_PID_FILE}"; then
        log "jupyter already running (pid $(cat "${JUPYTER_PID_FILE}"))"
        return 0
    fi

    if [ -z "${JUPYTER_TOKEN:-}" ]; then
        if [ -f "${RUN_DIR}/jupyter.token" ]; then
            JUPYTER_TOKEN="$(cat "${RUN_DIR}/jupyter.token")"
        else
            JUPYTER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
            echo -n "${JUPYTER_TOKEN}" > "${RUN_DIR}/jupyter.token"
        fi
    fi
    export JUPYTER_TOKEN

    log "starting jupyterlab (token in ${RUN_DIR}/jupyter.token)"
    nohup "${JUPYTER_ENV}/bin/jupyter" lab \
        --config="${CONFIG_DIR}/jupyter/jupyter_server_config.py" \
        >> "${LOG_DIR}/jupyter.log" 2>&1 &
    echo $! > "${JUPYTER_PID_FILE}"
}

stop_jupyter() {
    if pid_alive "${JUPYTER_PID_FILE}"; then
        log "stopping jupyter (pid $(cat "${JUPYTER_PID_FILE}"))"
        kill "$(cat "${JUPYTER_PID_FILE}")" 2>/dev/null || true
        for _ in $(seq 1 20); do
            pid_alive "${JUPYTER_PID_FILE}" || break
            sleep 0.2
        done
        rm -f "${JUPYTER_PID_FILE}"
    fi
}

configure_ssh() {
    local ssh_dir="${CONFIG_DIR}/ssh"
    mkdir -p "${ssh_dir}" /run/sshd /root/.ssh
    chmod 700 /root/.ssh

    # Host keys live on the persistent volume so they're generated once and
    # reused across restarts (no "host key changed" warnings on reconnect).
    for t in rsa ed25519; do
        if [ ! -f "${ssh_dir}/ssh_host_${t}_key" ]; then
            log "generating ssh host key: ${t}"
            ssh-keygen -q -t "${t}" -f "${ssh_dir}/ssh_host_${t}_key" -N ""
        fi
    done

    # vast.ai injects the account's SSH public key(s) via $PUBLIC_KEY.
    : > /root/.ssh/authorized_keys
    for var in PUBLIC_KEY SSH_PUBLIC_KEY; do
        if [ -n "${!var:-}" ]; then
            printf '%s\n' "${!var}" >> /root/.ssh/authorized_keys
        fi
    done
    chmod 600 /root/.ssh/authorized_keys
}

start_sshd() {
    if pid_alive "${SSHD_PID_FILE}"; then
        log "sshd already running (pid $(cat "${SSHD_PID_FILE}"))"
        return 0
    fi
    configure_ssh
    log "starting sshd on port 22"
    /usr/sbin/sshd \
        -o "HostKey=${CONFIG_DIR}/ssh/ssh_host_rsa_key" \
        -o "HostKey=${CONFIG_DIR}/ssh/ssh_host_ed25519_key" \
        -o "PermitRootLogin=prohibit-password" \
        -o "PasswordAuthentication=no" \
        -o "PidFile=${SSHD_PID_FILE}"
}

stop_sshd() {
    if pid_alive "${SSHD_PID_FILE}"; then
        log "stopping sshd"
        kill "$(cat "${SSHD_PID_FILE}")" 2>/dev/null || true
        rm -f "${SSHD_PID_FILE}"
    fi
}

configure_hf_token() {
    if [ -n "${HF_TOKEN:-}" ]; then
        log "configuring huggingface-cli with HF_TOKEN"
        huggingface-cli login --token "${HF_TOKEN}" --add-to-git-credential >/dev/null 2>&1 \
            || log "warning: huggingface-cli login failed"
    fi
}
