#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[deploy-agentic] $*"; }

log "Deploying agentic ML pipeline (individual identities, AuthBridge, scope narrowing)..."

# 1. Namespace + RBAC
kubectl apply -f "${REPO_ROOT}/k8s/agentic/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/agentic/rbac.yaml"

# 2. AuthBridge routes ConfigMap
kubectl apply -f "${REPO_ROOT}/k8s/agentic/authbridge-routes.yaml"

# 3. Services
kubectl apply -f "${REPO_ROOT}/k8s/agentic/services.yaml"

# 4. Deployments (agents + model-registry)
# Kagenti webhook auto-injects AuthBridge sidecars for pods with kagenti.io/type=agent
kubectl apply -f "${REPO_ROOT}/k8s/agentic/deployments.yaml"

# 5. Wait for pods
log "Waiting for pods..."
kubectl wait --for=condition=ready pod -l app -n agentic-ml --timeout=180s || true

# 6. Configure Keycloak (realm, clients, scopes)
log "Configuring Keycloak..."
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak-service.keycloak.svc.cluster.local:8080}"

# Run configure-keycloak.sh from inside the cluster via a job
kubectl run keycloak-config --rm -i --restart=Never \
  --image=python:3.12-slim \
  -n agentic-ml \
  --env="KEYCLOAK_URL=${KEYCLOAK_URL}" \
  --env="KEYCLOAK_ADMIN=admin" \
  --env="KEYCLOAK_ADMIN_PASSWORD=admin" \
  --command -- bash -c "
    apt-get update -qq && apt-get install -qq -y curl > /dev/null 2>&1
    $(cat "${REPO_ROOT}/scripts/configure-keycloak.sh")
  " || {
    log "WARNING: Keycloak configuration job failed. You may need to run configure-keycloak.sh manually."
  }

log "Agentic namespace deployed"
kubectl get pods -n agentic-ml

# 7. Check AgentCard CRDs (created by Kagenti operator)
log "Checking AgentCards..."
kubectl get agentcards -n agentic-ml 2>/dev/null || log "AgentCard CRDs not yet available (operator may still be syncing)"
