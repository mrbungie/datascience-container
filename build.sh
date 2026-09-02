#!/usr/bin/env bash
# Usage: ./build.sh cpu|gpu [extra docker build args...]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

variant="${1:-cpu}"
shift || true

case "$variant" in
    cpu)
        base_image="ubuntu:24.04"
        tag="datascience:cpu"
        ;;
    gpu)
        base_image="nvidia/cuda:13.3.1-runtime-ubuntu24.04"
        tag="datascience:gpu"
        ;;
    *)
        echo "usage: $0 [cpu|gpu]" >&2
        exit 1
        ;;
esac

docker build -t "$tag" --build-arg "BASE_IMAGE=${base_image}" "$@" .
echo "built ${tag} (base: ${base_image})"
