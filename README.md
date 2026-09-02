# datascience-container

Imagen Docker de propósito general para análisis en instancias de vast.ai,
con o sin GPU.

## Qué trae

- `uv` (gestor de paquetes/proyectos Python) + JupyterLab en un venv aislado
  (`/opt/venvs/jupyter`), sin ensuciar el entorno de tus proyectos.
- `nginx` como reverse proxy delante de Jupyter, con soporte de websockets.
- `duckdb` — se baja la última release de GitHub en el momento del build.
- CLIs de IA: `claude`, `gemini`, `codex` (vía npm/Node 22).
- Dev tools: git, gh (GitHub CLI), build-essential, neovim, tmux, ripgrep, fzf, jq, htop, ncdu, tree.
- Transferencia de datos: rclone, awscli v2, gsutil, huggingface-cli (`hf`), `vastai` (CLI de vast.ai).
- `cron`, con un crontab persistente en `/workspace/config/cron/crontab` y
  un watchdog opcional de auto-apagado por inactividad (ver más abajo).
- `tini` como PID 1 (vía `ENTRYPOINT`) — reaping correcto de procesos zombie.
- `sshd` propio en el puerto 22, con la key pública que vast.ai inyecta por
  `$PUBLIC_KEY`. Solo se usa cuando el `ENTRYPOINT` de esta imagen es el que
  manda (`docker run` directo, o launch mode "Entrypoint" en vast.ai) — ver
  "En vast.ai" más abajo para el modo SSH.
- Nada de librerías Python de proyecto preinstaladas (numpy/pandas/torch/etc.)
  — eso lo instala cada quien con `uv` al bajar su repo.

No hay una imagen separada "cpu" vs "gpu": es el mismo `Dockerfile`,
parametrizado por `--build-arg BASE_IMAGE`. La variante GPU solo cambia la
imagen base a `nvidia/cuda:13.3.1-runtime-ubuntu24.04`; el driver y las libs
CUDA los monta en runtime el NVIDIA Container Toolkit (`--gpus all`), no van
en la imagen.

## Build

```bash
./build.sh cpu   # ubuntu:24.04
./build.sh gpu   # nvidia/cuda:13.3.1-runtime-ubuntu24.04
```

## Run local

```bash
docker run -d \
  --gpus all \               # omitir en la variante cpu
  -p 8080:80 \
  -v ds-workspace:/workspace \
  -e BASIC_AUTH_PASSWORD=cambiame \
  -e BASIC_AUTH_USER=vast \  # opcional, default "vast"
  -e HF_TOKEN=hf_xxx \       # opcional, autologin de huggingface-cli
  --name ds datascience:gpu
```

Si seteás `BASIC_AUTH_PASSWORD`, nginx pide usuario/contraseña (HTTP Basic)
antes de llegar a Jupyter — además del token propio de Jupyter, no en vez de
él. Sin esa env var, nginx queda sin auth propia (solo el token de Jupyter).

`/workspace` es el volumen persistente: ahí viven notebooks, y también
`config/` (nginx + jupyter), `logs/` y `run/` (pids, token de Jupyter). Al
primer arranque se semillan los configs default; en arranques siguientes
sobre el mismo volumen se reusan tal cual quedaron, sin partir de cero.

Token de Jupyter: se genera solo y queda en `/workspace/run/jupyter.token`
(o fijalo vos con `-e JUPYTER_TOKEN=...`).

`huggingface-cli` / `hf`: si pasás `-e HF_TOKEN=...`, el entrypoint corre
`huggingface-cli login --token` al arrancar, así queda logueado sin pasos
manuales (además, la librería `huggingface_hub` ya lee `HF_TOKEN` sola en
cualquier caso).

```bash
docker exec ds cat /workspace/run/jupyter.token
```

Abrí `http://<host>:8080/?token=<ese-token>`.

## CI: build + publish a GHCR

`.github/workflows/docker-publish.yml` builda las dos variantes (cpu/gpu) en
cada push a `main` (o manualmente desde Actions) y las publica en
`ghcr.io/mrbungie/datascience-container:cpu` y `:gpu` (más un tag por commit
`:cpu-<sha>` / `:gpu-<sha>`). No requiere secrets: usa el `GITHUB_TOKEN`
automático del repo con permiso `packages: write`.

Nada que configurar aparte de:
1. Pushear este repo a `github.com/mrbungie/datascience-container`.
2. La primera vez, el paquete puede quedar **privado** por default en GHCR
   — si lo querés público: Settings del paquete (en la org/usuario de
   GitHub) → Change visibility → Public.

```bash
docker pull ghcr.io/mrbungie/datascience-container:gpu
```

## En vast.ai

vast.ai tiene tres launch modes (**Entrypoint**, **SSH**, **Jupyter**). Los
modos SSH y Jupyter inyectan su propio script de setup y **reemplazan el
`ENTRYPOINT` de la imagen** — si vas a usar alguno de esos dos, no confíes en
que nuestro `entrypoint.sh` corra solo.

Pasos comunes a cualquier modo:
1. Pusheá la imagen a un registry (Docker Hub, GHCR, etc.) y usala como
   template.
2. Exponé el puerto 80 (nginx) en el template — vast.ai lo mapea a un puerto
   público.
3. Montá el disco persistente de la instancia en `/workspace`.
4. Para instancias GPU, vast.ai ya te da el runtime nvidia — no hace falta
   nada extra aparte de usar la imagen `gpu`.

### Opción A — launch mode "Entrypoint"

Nuestro `ENTRYPOINT` (`tini` + `entrypoint.sh`) corre tal cual: levanta
sshd propio (usando `$PUBLIC_KEY`), nginx, jupyter y cron. Es el modo más
parecido a "Run local" de arriba. No hace falta configurar nada más en el
template.

### Opción B — launch mode "SSH" + onstart

vast.ai levanta su propio sshd (con `$PUBLIC_KEY`) y pisa nuestro
`ENTRYPOINT`, así que el resto de los servicios (nginx, jupyter, cron) hay
que arrancarlos desde el campo **"On-start Script"** del template. Poné la
invocación explícita, no solo la ruta (el campo puede no respetar shebang/
permisos de ejecución):

```bash
bash /opt/scripts/onstart.sh
```

Ese script hace lo mismo que `entrypoint.sh` menos sshd (que ya lo maneja
vast.ai) — arranca nginx, jupyter y cron, y no bloquea (todo queda corriendo
en background). También vuelca el entorno actual a `/etc/environment`
(`sync_env_to_etc_environment` en `lib.sh`), porque vast.ai a veces no
propaga sus predefined vars (`$CONTAINER_ID`, `$CONTAINER_API_KEY`, etc.) a
sesiones SSH posteriores — con esto quedan disponibles igual en cualquier
login nuevo. Si por error corrés `/opt/scripts/start.sh all` o
`restart.sh all` en este modo, el intento de levantar nuestro propio sshd
detecta el puerto 22 ya ocupado y lo salta solo (no rompe nada, solo loguea
un aviso).

### Auto-apagado por inactividad (opcional)

`scripts/idle_shutdown.sh` corre por cron (en cualquiera de los dos modos)
si seteás `IDLE_SHUTDOWN_ENABLE=1` como env var del template. Chequea CPU,
RAM, y si hay GPU, utilization% y VRAM%, con umbrales configurables:

```
IDLE_SHUTDOWN_ENABLE=1
IDLE_CHECK_INTERVAL_MINUTES=5     # cada cuánto chequea (default 5)
IDLE_GRACE_MINUTES=30             # minutos seguidos por debajo del umbral antes de actuar (default 30)
IDLE_CPU_THRESHOLD_PCT=15
IDLE_RAM_THRESHOLD_PCT=20
IDLE_GPU_THRESHOLD_PCT=5
IDLE_VRAM_THRESHOLD_PCT=10
IDLE_ACTION=exit                  # "exit" (para la instancia) o "notify" (solo loguea/webhook)
IDLE_WEBHOOK_URL=https://...      # opcional, aviso al detectar idle
```

La acción `exit` intenta `vastai stop instance $CONTAINER_ID` (usa las env
vars `CONTAINER_ID`/`CONTAINER_API_KEY` que vast.ai debería inyectar solo;
si en tu instancia no aparecen, corré `env | grep -i container` para
confirmarlo — la doc de vast.ai dice que a veces hay que exportarlas a mano
a `/etc/environment` en sesiones SSH). Si no hay `CONTAINER_ID` o el CLI
`vastai` no está disponible, cae a `kill -TERM 1` — que **solo sirve** en
modo Entrypoint (ahí sí somos PID 1); en modo SSH/onstart no hace nada útil,
así que probá primero con `IDLE_ACTION=notify` para confirmar que detecta
bien la inactividad antes de dejarlo apagar la instancia sola.

Logs en `/workspace/logs/idle-shutdown.log`.

## Extender / reiniciar sin recrear el contenedor

Los scripts viven en `/opt/scripts/` dentro del contenedor:

```bash
# agregar un servicio propio: dejá un .conf en conf.d y recargá nginx
vi /workspace/config/nginx/conf.d/mi-servicio.conf
/opt/scripts/restart.sh nginx      # reload sin downtime, no mata Jupyter

# jupyter necesita reinicio real para tomar cambios de config
vi /workspace/config/jupyter/jupyter_server_config.py
/opt/scripts/restart.sh jupyter

# tus propios cronjobs, o ajustar los thresholds de idle-shutdown a mano
vi /workspace/config/cron/crontab
/opt/scripts/restart.sh cron

# start/stop individual o de todo (en modo onstart, evitá "all": ver arriba)
/opt/scripts/stop.sh nginx
/opt/scripts/start.sh nginx
/opt/scripts/restart.sh all
```

Como todo esto lee de `/workspace/config` (volumen persistente), un restart
del contenedor sobre el mismo volumen no vuelve a copiar los defaults ni
pierde tus cambios.

## Posibles extras que no incluí (dejo la decisión a quien lo use)

- Stack de análisis Python (numpy/pandas/polars/pyarrow/scikit-learn) o
  PyTorch con CUDA — a propósito no van preinstalados, se agregan por
  proyecto con `uv`.
- `nvitop`/`gpustat`/`py3nvml` para monitoreo de GPU desde notebook — fácil
  de sumar con `uv tool install nvitop` si lo necesitás.
- TLS/HTTPS en nginx (certs self-signed o Let's Encrypt) — hoy sirve HTTP
  plano en el puerto 80.
