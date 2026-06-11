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
KIND_NODE="${KIND_CLUSTER}-control-plane"
REGISTRY_NAME="ttg-registry"
REGISTRY_PORT=5000
KIND_NETWORK="kind"

KAGENTI_REPO="${KAGENTI_REPO:-}"
if [[ -z "$KAGENTI_REPO" ]]; then
  if [[ -d "${REPO_ROOT}/../kagenti" ]]; then
    KAGENTI_REPO="${REPO_ROOT}/../kagenti"
  fi
fi

log() { echo "[build-images] $*"; }

# --- Registry lifecycle ---
ensure_registry() {
  if ${CONTAINER_CMD} ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    log "Registry '${REGISTRY_NAME}' already running"
  else
    if ${CONTAINER_CMD} ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
      log "Starting existing registry '${REGISTRY_NAME}'..."
      ${CONTAINER_CMD} start "${REGISTRY_NAME}"
    else
      log "Creating registry '${REGISTRY_NAME}' on network '${KIND_NETWORK}'..."
      ${CONTAINER_CMD} run -d --name "${REGISTRY_NAME}" \
        --network "${KIND_NETWORK}" \
        -p "${REGISTRY_PORT}:5000" \
        docker.io/library/registry:2
    fi
  fi

  REGISTRY_IP=$(${CONTAINER_CMD} inspect "${REGISTRY_NAME}" \
    --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}")
  [[ -n "$REGISTRY_IP" ]] || { log "ERROR: Could not get registry IP"; exit 1; }
  log "Registry IP: ${REGISTRY_IP}"
}

configure_kind_node() {
  log "Configuring Kind node to pull from ${REGISTRY_NAME}:${REGISTRY_PORT}..."

  # Add /etc/hosts entry so containerd resolves ttg-registry
  if ! ${CONTAINER_CMD} exec "${KIND_NODE}" grep -q "${REGISTRY_NAME}" /etc/hosts 2>/dev/null; then
    ${CONTAINER_CMD} exec "${KIND_NODE}" sh -c \
      "echo '${REGISTRY_IP} ${REGISTRY_NAME}' >> /etc/hosts"
    log "  Added ${REGISTRY_IP} → ${REGISTRY_NAME} to Kind node /etc/hosts"
  fi

  # Create containerd certs.d config for insecure HTTP registry
  ${CONTAINER_CMD} exec "${KIND_NODE}" mkdir -p "/etc/containerd/certs.d/${REGISTRY_NAME}:${REGISTRY_PORT}"
  ${CONTAINER_CMD} exec "${KIND_NODE}" sh -c "cat > /etc/containerd/certs.d/${REGISTRY_NAME}:${REGISTRY_PORT}/hosts.toml <<EOF
[host.\"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF"
  log "  containerd certs.d configured for ${REGISTRY_NAME}:${REGISTRY_PORT}"
}

push_image() {
  local local_name="$1"
  local registry_name="$2"
  local full_ref="127.0.0.1:${REGISTRY_PORT}/${registry_name}"
  log "Pushing ${registry_name} → ${full_ref}"
  ${CONTAINER_CMD} tag "${local_name}" "${full_ref}"
  ${CONTAINER_CMD} push --tls-verify=false "${full_ref}"
}

# --- Main ---

log "Building demo images..."

ensure_registry
configure_kind_node

log "Building demo-ml-agent"
${CONTAINER_CMD} build -t demo-ml-agent:latest "${REPO_ROOT}/agent/"

log "Building demo-model-registry"
${CONTAINER_CMD} build -t demo-model-registry:latest "${REPO_ROOT}/model-registry/"

log "Building keycloak-agentic-spi"
${CONTAINER_CMD} build -t keycloak-agentic-spi:latest "${REPO_ROOT}/keycloak-spi/"

log "Building trust-graph-ui"
${CONTAINER_CMD} build -t trust-graph-ui:latest "${REPO_ROOT}/trust-graph-ui/"

if [[ -n "$KAGENTI_REPO" && -d "${KAGENTI_REPO}/kagenti/auth/agent-oauth-secret" ]]; then
  log "Building agent-oauth-secret"
  ${CONTAINER_CMD} build -t agent-oauth-secret:v0.7.0-alpha.1 \
    -f "${KAGENTI_REPO}/kagenti/auth/agent-oauth-secret/Dockerfile" \
    "${KAGENTI_REPO}/kagenti/"
fi

log "Pulling proxy-init (for AuthBridge iptables interception)"
${CONTAINER_CMD} pull ghcr.io/kagenti/kagenti-extensions/proxy-init:v0.6.0-alpha.3
${CONTAINER_CMD} tag ghcr.io/kagenti/kagenti-extensions/proxy-init:v0.6.0-alpha.3 proxy-init:v0.6.0-alpha.3

log "Pushing images to local registry (127.0.0.1:${REGISTRY_PORT})..."

push_image "localhost/demo-ml-agent:latest"          "demo-ml-agent:latest"
push_image "localhost/demo-model-registry:latest"    "demo-model-registry:latest"
push_image "localhost/keycloak-agentic-spi:latest"   "keycloak-agentic-spi:latest"
push_image "localhost/trust-graph-ui:latest"         "trust-graph-ui:latest"
push_image "localhost/proxy-init:v0.6.0-alpha.3"     "proxy-init:v0.6.0-alpha.3"

if ${CONTAINER_CMD} image exists localhost/agent-oauth-secret:v0.7.0-alpha.1 2>/dev/null; then
  push_image "localhost/agent-oauth-secret:v0.7.0-alpha.1" "agent-oauth-secret:v0.7.0-alpha.1"
  # Helm job references ghcr.io path — pull from our registry into containerd and retag
  ${CONTAINER_CMD} exec "${KIND_NODE}" crictl pull --creds "" "ttg-registry:${REGISTRY_PORT}/agent-oauth-secret:v0.7.0-alpha.1" || true
  ${CONTAINER_CMD} exec "${KIND_NODE}" ctr --namespace=k8s.io images tag \
    "ttg-registry:${REGISTRY_PORT}/agent-oauth-secret:v0.7.0-alpha.1" \
    "ghcr.io/kagenti/kagenti/agent-oauth-secret:v0.7.0-alpha.1" 2>/dev/null || true
fi

log "All images built and pushed to ${REGISTRY_NAME}"
