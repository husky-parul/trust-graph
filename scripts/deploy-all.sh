#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KAGENTI_REPO="${KAGENTI_REPO:-}"
KIND_CLUSTER="${KIND_CLUSTER:-kagenti}"

log() { echo "[deploy-all] $*"; }
die() { echo "[deploy-all] ERROR: $*" >&2; exit 1; }

# --- Pre-flight checks ---
log "Checking prerequisites..."
command -v kind >/dev/null || die "kind not found. Install: https://kind.sigs.k8s.io/"
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm >/dev/null || die "helm not found"

if command -v docker &>/dev/null; then
  CONTAINER_CMD="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
else
  die "docker or podman required"
fi
log "Container engine: ${CONTAINER_CMD}"

# --- Locate Kagenti repo ---
if [[ -z "$KAGENTI_REPO" ]]; then
  if [[ -d "${REPO_ROOT}/../kagenti" ]]; then
    KAGENTI_REPO="${REPO_ROOT}/../kagenti"
  else
    die "Set KAGENTI_REPO to the path of the kagenti/kagenti repo clone"
  fi
fi
log "Kagenti repo: ${KAGENTI_REPO}"

# --- Step 1: Create cluster if needed ---
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  log "Step 1: Kind cluster '${KIND_CLUSTER}' already exists — skipping creation"
else
  log "Step 1: Creating Kind cluster via Kagenti Ansible installer..."
  KAGENTI_INSTALLER="${KAGENTI_REPO}/deployments/ansible/run-install.sh"
  [[ -f "$KAGENTI_INSTALLER" ]] || die "Kagenti installer not found at ${KAGENTI_INSTALLER}"
  bash "${KAGENTI_INSTALLER}" --env dev
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER}" &>/dev/null || die "Cannot connect to cluster"

# --- Step 2: Build & load images ---
log "Step 2: Building and loading images..."
bash "${SCRIPT_DIR}/build-images.sh"

# --- Step 3: Deploy classic namespace ---
log "Step 3: Deploying classic ML pipeline..."
bash "${SCRIPT_DIR}/deploy-classic.sh"

# --- Step 4: Deploy agentic namespace ---
log "Step 4: Deploying agentic ML pipeline..."
bash "${SCRIPT_DIR}/deploy-agentic.sh"

# --- Step 5: Deploy trust graph UI ---
log "Step 5: Deploying trust graph UI..."
kubectl apply -f "${REPO_ROOT}/k8s/trust-graph-ui/deployment.yaml"
kubectl wait --for=condition=ready pod -l app=trust-graph-ui -n trust-graph-ui --timeout=120s || true
kubectl get pods -n trust-graph-ui

# --- Step 6: Enable Keycloak events ---
log "Step 6: Enabling Keycloak event logging..."
kubectl run kc-events-$$ --image=curlimages/curl --rm -i --restart=Never -- sh -c '
  TOKEN=$(curl -sf -X POST \
    "http://keycloak-service.keycloak.svc.cluster.local:8080/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
    | sed "s/.*access_token\":\"//;s/\".*//")
  curl -sf -X PUT \
    "http://keycloak-service.keycloak.svc.cluster.local:8080/admin/realms/demo" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"eventsEnabled\":true,\"eventsListeners\":[\"jboss-logging\"],\"enabledEventTypes\":[\"TOKEN_EXCHANGE\",\"LOGIN\",\"CLIENT_LOGIN\",\"CODE_TO_TOKEN\"],\"eventsExpiration\":86400}" \
    -o /dev/null -w "Keycloak events: HTTP %{http_code}\n"
' 2>/dev/null || log "WARNING: Could not enable Keycloak events"

# --- Step 7: Run tests ---
log "Step 7: Running tests..."
bash "${SCRIPT_DIR}/test-demo.sh" || log "WARNING: Some tests failed — check output above"

# --- Step 8: Start port-forwards ---
log "Step 8: Starting port-forwards..."
bash "${SCRIPT_DIR}/port-forward.sh"

log ""
log "=== Deployment complete ==="
log ""
log "Access points:"
log "  Trust Graph UI:              http://localhost:8090"
log "  Data Agent (A2A):            http://localhost:8000/.well-known/agent-card.json"
log "  Training Agent (A2A):        http://localhost:8001/.well-known/agent-card.json"
log "  Eval Agent (A2A):            http://localhost:8002/.well-known/agent-card.json"
log "  Deploy Agent (A2A):          http://localhost:8003/.well-known/agent-card.json"
log "  Model Registry (agentic):    http://localhost:8080"
log "  Model Registry (classic):    http://localhost:8081"
log ""
log "Demo user: alice / demo (realm: demo)"
log "Stop port-forwards: bash scripts/port-forward.sh --stop"
