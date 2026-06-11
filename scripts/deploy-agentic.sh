#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[deploy-agentic] $*"; }

log "Deploying agentic ML pipeline (individual identities, AuthBridge, scope narrowing)..."

# 0. Replace stock Keycloak with custom SPI image (act-claim injection + scope narrowing)
log "Patching Keycloak with agentic SPI image..."
kubectl patch statefulset -n keycloak keycloak --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"ttg-registry:5000/keycloak-agentic-spi:latest\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Always\"}
]"
# Add KC_FEATURES if not already present
KC_FEATURES="client-auth-federated,kubernetes-service-accounts,token-exchange,token-exchange-standard"
if ! kubectl get statefulset -n keycloak keycloak -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q KC_FEATURES; then
  kubectl patch statefulset -n keycloak keycloak --type='json' \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"KC_FEATURES\",\"value\":\"${KC_FEATURES}\"}}]"
else
  IDX=$(kubectl get statefulset -n keycloak keycloak -o json | python3 -c "import sys,json; envs=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']; print(next(i for i,e in enumerate(envs) if e['name']=='KC_FEATURES'))")
  kubectl patch statefulset -n keycloak keycloak --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${IDX}/value\",\"value\":\"${KC_FEATURES}\"}]"
fi
log "Waiting for Keycloak to restart with SPI..."
kubectl rollout status statefulset -n keycloak keycloak --timeout=300s

# 1. Namespace + RBAC
kubectl apply -f "${REPO_ROOT}/k8s/agentic/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/agentic/rbac.yaml"

# 2. AuthBridge routes ConfigMap
kubectl apply -f "${REPO_ROOT}/k8s/agentic/authbridge-routes.yaml"

# 2b. Sidecar ConfigMaps (envoy, spiffe-helper, authbridge-config)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/sidecar-configmaps.yaml"

# 2c. Environments ConfigMap (Keycloak credentials for client-registration sidecar)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/environments-configmap.yaml"

# 3. Services (needed before Agent CRs so the operator can resolve endpoints)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/services.yaml"

# 4. Agent CRs — operator creates Deployments with AuthBridge sidecars injected
log "Applying Agent CRs (operator handles Deployments + sidecar injection)..."
kubectl apply -f "${REPO_ROOT}/k8s/agentic/agent-crs.yaml"

# 5. Wait for pods
log "Waiting for pods..."
for agent in data-agent training-agent eval-agent deploy-agent model-registry; do
  kubectl rollout status deployment/"$agent" -n agentic-ml --timeout=180s || true
done

# 6. Configure Keycloak (realm, clients, scopes)
log "Configuring Keycloak..."
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak-service.keycloak.svc.cluster.local:8080}"

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

# 7. Check AgentCards (created by operator from Agent CRs)
log "Checking AgentCards..."
kubectl get agentcards -n agentic-ml 2>/dev/null || log "AgentCard CRDs not yet available (operator may still be syncing)"

log "Agentic namespace deployed"
kubectl get pods -n agentic-ml
