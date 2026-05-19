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
if ! command -v ansible-playbook >/dev/null; then
  log "ansible-playbook not found — installing via pip..."
  pip install ansible-core
fi
if ! ansible-galaxy collection list kubernetes.core &>/dev/null; then
  log "kubernetes.core collection not found — installing..."
  ansible-galaxy collection install kubernetes.core
fi

# --- Locate Kagenti repo ---
if [[ -z "$KAGENTI_REPO" ]]; then
  if [[ -d "${REPO_ROOT}/../kagenti" ]]; then
    KAGENTI_REPO="${REPO_ROOT}/../kagenti"
  else
    die "Set KAGENTI_REPO to the path of the kagenti/kagenti repo clone"
  fi
fi

KAGENTI_INSTALLER="${KAGENTI_REPO}/deployments/ansible/run-install.sh"
[[ -f "$KAGENTI_INSTALLER" ]] || die "Kagenti installer not found at ${KAGENTI_INSTALLER}"

# --- Step 1: Install Kagenti platform via Ansible installer ---
log "Step 1: Installing Kagenti platform (Ansible-based)..."
log "  This creates a Kind cluster and deploys: Istio, SPIRE, Keycloak, OTel, Kiali, Kagenti operators"
# Detect container engine: prefer podman if available
if command -v podman >/dev/null; then
  CONTAINER_ENGINE="podman"
  export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
elif command -v docker >/dev/null; then
  CONTAINER_ENGINE="docker"
else
  die "Neither podman nor docker found"
fi
log "  Using container engine: ${CONTAINER_ENGINE}"
bash "${KAGENTI_INSTALLER}" --env dev --extra-vars "{\"container_engine\": \"${CONTAINER_ENGINE}\"}"

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

# --- Step 5: Verify ---
log "Step 5: Verification..."
bash "${SCRIPT_DIR}/test-demo.sh" || log "Some tests failed — check output above"

log ""
log "=== Setup complete ==="
log ""
log "Access points:"
log "  Kagenti UI:     http://kagenti-ui.localtest.me:8080"
log "  Keycloak:       http://keycloak.localtest.me:8080 (admin/admin)"
log "  Kiali:          http://kiali.localtest.me:8080"
log "  Trust Graph UI: http://trust-graph.localtest.me:8080"
log ""
log "Demo user: alice / demo (realm: demo)"
