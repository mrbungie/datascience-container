# syntax=docker/dockerfile:1
#
# Datascience container for vast.ai
#
# CPU build:
#   docker build -t datascience:cpu --build-arg BASE_IMAGE=ubuntu:24.04 .
#
# GPU build (CUDA 13.3, runtime-only — driver/libs come from the host via
# the NVIDIA container toolkit, `--gpus all` on `docker run`):
#   docker build -t datascience:gpu --build-arg BASE_IMAGE=nvidia/cuda:13.3.1-runtime-ubuntu24.04 .
#
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PATH=/root/.local/bin:/opt/venvs/jupyter/bin:/root/.cargo/bin:$PATH \
    WORKSPACE=/workspace

# ---------------------------------------------------------------------------
# Base OS packages: dev tools, git, editors, CLI quality-of-life, nginx
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    wget \
    gnupg \
    software-properties-common \
    git \
    openssh-client \
    unzip \
    zip \
    less \
    vim \
    neovim \
    tmux \
    tree \
    htop \
    ncdu \
    jq \
    ripgrep \
    fzf \
    nginx \
    openssl \
    openssh-server \
    python3 \
    python3-venv \
    locales \
  && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js (required by the claude / gemini / codex CLIs)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GitHub CLI
# ---------------------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# AI CLIs
# ---------------------------------------------------------------------------
RUN npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    @openai/codex \
  && npm cache clean --force

# ---------------------------------------------------------------------------
# uv (Python package/project manager) + a dedicated venv for JupyterLab
# ---------------------------------------------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv venv /opt/venvs/jupyter --python 3.12 \
  && uv pip install --python /opt/venvs/jupyter/bin/python \
       jupyterlab jupyterlab-git ipywidgets

# ---------------------------------------------------------------------------
# DuckDB CLI — always pulls the latest GitHub release at build time
# ---------------------------------------------------------------------------
RUN set -eux; \
    ver="$(curl -fsSL https://api.github.com/repos/duckdb/duckdb/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"; \
    curl -fsSL -o /tmp/duckdb.zip "https://github.com/duckdb/duckdb/releases/download/${ver}/duckdb_cli-linux-amd64.zip"; \
    unzip -q /tmp/duckdb.zip -d /usr/local/bin; \
    chmod +x /usr/local/bin/duckdb; \
    rm /tmp/duckdb.zip; \
    duckdb --version

# ---------------------------------------------------------------------------
# Data / cloud transfer tools: rclone, awscli v2, gsutil, huggingface-cli
# ---------------------------------------------------------------------------
RUN curl -fsSL https://rclone.org/install.sh | bash

RUN set -eux; \
    curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws

RUN uv tool install gsutil \
  && uv tool install "huggingface_hub[cli]"
ENV PATH=/root/.local/bin:$PATH

# ---------------------------------------------------------------------------
# Runtime layout
# ---------------------------------------------------------------------------
RUN mkdir -p ${WORKSPACE} /opt/defaults
COPY config/ /opt/defaults/config/
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

WORKDIR ${WORKSPACE}
VOLUME ["${WORKSPACE}"]

EXPOSE 80 443 8888 22

ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
