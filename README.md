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
- Transferencia de datos: rclone, awscli v2, gsutil, huggingface-cli (`hf`).
- `sshd` en el puerto 22, con la key pública que vast.ai inyecta por
  `$PUBLIC_KEY` (así el botón "Connect via SSH" de vast.ai funciona).
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

1. Pusheá la imagen a un registry (Docker Hub, GHCR, etc.) y usala como
   template, o subí el Dockerfile como "on-start" build si tu template lo
   permite.
2. Exponé el puerto 80 (nginx) en el template — vast.ai lo mapea a un puerto
   público.
3. Montá el disco persistente de la instancia en `/workspace`.
4. Para instancias GPU, vast.ai ya te da el runtime nvidia — no hace falta
   nada extra aparte de usar la imagen `gpu`.
5. SSH: vast.ai pasa la(s) key(s) pública(s) de tu cuenta a la instancia por
   la env var `PUBLIC_KEY` — el `entrypoint` las escribe en
   `/root/.ssh/authorized_keys` y levanta `sshd` en el puerto 22 solo. No
   hace falta nada manual siempre que el template exponga el puerto 22.

## Extender / reiniciar sin recrear el contenedor

Los scripts viven en `/opt/scripts/` dentro del contenedor:

```bash
# agregar un servicio propio: dejá un .conf en conf.d y recargá nginx
vi /workspace/config/nginx/conf.d/mi-servicio.conf
/opt/scripts/restart.sh nginx      # reload sin downtime, no mata Jupyter

# jupyter necesita reinicio real para tomar cambios de config
vi /workspace/config/jupyter/jupyter_server_config.py
/opt/scripts/restart.sh jupyter

# start/stop individual o de todo
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
