#!/bin/bash

set -euo pipefail
REGISTRY="${REGISTRY:-btungut}"
TAG="${TAG:-latest}"

UBUNTU_BASE_IMAGE="${UBUNTU_BASE_IMAGE:-ubuntu}"
UBUNTU_BASE_IMAGE_TAG="${UBUNTU_BASE_IMAGE_TAG:-24.04}"
# Leave empty to use the pinned defaults from the Dockerfile
UBUNTU_BASE_IMAGE_DIGEST="${UBUNTU_BASE_IMAGE_DIGEST:-}"
UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT:-}"

BUILD_ARGS=(
    --build-arg "ARG_UBUNTU_BASE_IMAGE=${UBUNTU_BASE_IMAGE}"
    --build-arg "ARG_UBUNTU_BASE_IMAGE_TAG=${UBUNTU_BASE_IMAGE_TAG}"
)
if [ -n "${UBUNTU_BASE_IMAGE_DIGEST}" ]; then
    BUILD_ARGS+=(--build-arg "ARG_UBUNTU_BASE_IMAGE_DIGEST=${UBUNTU_BASE_IMAGE_DIGEST}")
fi
if [ -n "${UBUNTU_SNAPSHOT}" ]; then
    BUILD_ARGS+=(--build-arg "ARG_UBUNTU_SNAPSHOT=${UBUNTU_SNAPSHOT}")
fi

docker build ./src \
    "${BUILD_ARGS[@]}" \
    --pull \
    -f ./Dockerfile \
    -t "${REGISTRY}/azure-devops-agent:${TAG}" \
    --progress=plain \
    "$@"
