#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v docker &>/dev/null; then
  CONTAINER_CMD="${CONTAINER_CMD:-docker}"
else
  CONTAINER_CMD="${CONTAINER_CMD:-podman}"
fi
KIND_CLUSTER="${KIND_CLUSTER:-kagenti}"

log() { echo "[build-images] $*"; }

log "Building demo images..."

log "Building demo-ml-agent"
${CONTAINER_CMD} build -t demo-ml-agent:latest "${REPO_ROOT}/agent/"

log "Building demo-model-registry"
${CONTAINER_CMD} build -t demo-model-registry:latest "${REPO_ROOT}/model-registry/"

log "Building keycloak-agentic-spi"
${CONTAINER_CMD} build -t keycloak-agentic-spi:latest "${REPO_ROOT}/keycloak-spi/"

log "Building trust-graph-ui"
${CONTAINER_CMD} build -t trust-graph-ui:latest "${REPO_ROOT}/trust-graph-ui/"

log "Loading images into Kind cluster '${KIND_CLUSTER}'..."

REGISTRY_PREFIX="registry.cr-system.svc.cluster.local:5000"
IMAGES=(demo-ml-agent demo-model-registry keycloak-agentic-spi trust-graph-ui)

load_via_kind() {
  local img="$1"
  kind load docker-image "${img}:latest" --name "${KIND_CLUSTER}" 2>/dev/null || \
    ${CONTAINER_CMD} save "${img}:latest" | kind load image-archive /dev/stdin --name "${KIND_CLUSTER}" 2>/dev/null
}

load_via_registry() {
  log "Falling back to in-cluster registry push..."

  # Start port-forward to registry if not already running
  if ! curl -sf http://127.0.0.1:5000/v2/ &>/dev/null; then
    kubectl port-forward -n cr-system svc/registry 5000:5000 &>/dev/null &
    REG_PF_PID=$!
    sleep 3
  fi

  for img in "${IMAGES[@]}"; do
    log "Pushing ${img}:latest → ${REGISTRY_PREFIX}/${img}:latest"
    ${CONTAINER_CMD} tag "${img}:latest" "127.0.0.1:5000/${img}:latest"
    ${CONTAINER_CMD} push --tls-verify=false "127.0.0.1:5000/${img}:latest"
  done

  if [[ -n "${REG_PF_PID:-}" ]]; then
    kill "$REG_PF_PID" 2>/dev/null || true
  fi
}

# Try kind load first; if it fails, push to in-cluster registry
if load_via_kind "${IMAGES[0]}"; then
  for img in "${IMAGES[@]:1}"; do
    log "Loading ${img}:latest"
    load_via_kind "${img}"
  done
else
  load_via_registry
fi

log "All images built and loaded"
