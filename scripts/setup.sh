#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KAGENTI_REPO="${KAGENTI_REPO:-}"

log() { echo "[setup] $*"; }
die() { echo "[setup] ERROR: $*" >&2; exit 1; }

# --- Pre-flight checks ---
command -v kind >/dev/null || die "kind not found. Install: https://kind.sigs.k8s.io/"
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm >/dev/null || die "helm not found"

# Cache sudo credentials upfront so the script doesn't hang mid-run
log "Requesting sudo (needed for inotify sysctl)..."
sudo -v
# Keep sudo alive in the background for long-running steps
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
# --- Locate Kagenti repo ---
if [[ -z "$KAGENTI_REPO" ]]; then
  if [[ -d "${REPO_ROOT}/../kagenti" ]]; then
    KAGENTI_REPO="${REPO_ROOT}/../kagenti"
  else
    die "Set KAGENTI_REPO to the path of the kagenti/kagenti repo clone"
  fi
fi

KAGENTI_INSTALLER="${KAGENTI_REPO}/scripts/kind/setup-kagenti.sh"
[[ -f "$KAGENTI_INSTALLER" ]] || die "Kagenti installer not found at ${KAGENTI_INSTALLER}"

# --- Step 1: Install Kagenti platform via Ansible installer ---
log "Step 1: Installing Kagenti platform (Ansible-based)..."
log "  This creates a Kind cluster and deploys: Istio, SPIRE, Keycloak, OTel, Kagenti operators"
# Detect container engine: prefer podman if available
if command -v podman >/dev/null; then
  export CONTAINER_ENGINE="podman"
  export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
elif command -v docker >/dev/null; then
  export CONTAINER_ENGINE="docker"
else
  die "Neither podman nor docker found"
fi
log "  Using container engine: ${CONTAINER_ENGINE}"
bash "${KAGENTI_INSTALLER}" --with-istio --with-spire --with-otel

# --- Step 1b: Fix inotify limits inside Kind node (Podman rootless shares host limits) ---
log "Raising inotify limits on Kind node..."
sudo sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192
kubectl rollout restart deployment -n kagenti-system kagenti-controller-manager || true
kubectl rollout restart deployment -n kagenti-webhook-system kagenti-webhook-controller-manager || true
kubectl rollout status deployment -n kagenti-system kagenti-controller-manager --timeout=120s || true
kubectl rollout status deployment -n kagenti-webhook-system kagenti-webhook-controller-manager --timeout=120s || true

# --- Step 2: Build demo images ---
log "Step 2: Building demo images..."
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

# --- Step 6: Enable Keycloak event logging ---
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

# --- Step 7: Verify ---
log "Step 7: Verification..."
bash "${SCRIPT_DIR}/test-demo.sh" || log "Some tests failed — check output above"

log ""
log "=== Setup complete ==="
log ""
log "Access points:"
log "  Kagenti UI:     http://kagenti-ui.localtest.me:8080"
log "  Keycloak:       http://keycloak.localtest.me:8080 (admin/admin)"
log "  Trust Graph UI: kubectl port-forward -n trust-graph-ui svc/trust-graph-ui 8090:8090"
log ""
log "Demo user: alice / demo (realm: demo)"
