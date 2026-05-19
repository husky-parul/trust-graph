#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[deploy-agentic] $*"; }

log "Deploying agentic ML pipeline (individual identities, AuthBridge, scope narrowing)..."

REGISTRY_PREFIX="registry.cr-system.svc.cluster.local:5000"

# 0. Replace stock Keycloak with custom SPI image (act-claim injection + scope narrowing)
log "Patching Keycloak with agentic SPI image..."
kubectl patch statefulset -n keycloak keycloak --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${REGISTRY_PREFIX}/keycloak-agentic-spi:latest\"},
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

# 2b. Sidecar ConfigMaps (envoy, spiffe-helper, authbridge)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/sidecar-configmaps.yaml"

# 2c. Environments ConfigMap (Keycloak credentials for client-registration sidecar)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/environments-configmap.yaml"

# 3. Agent CRs (operator creates Deployments, Services, and AgentCards)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/agent-crs.yaml"

# 4b. Patch POD_IP into proxy-init (webhook doesn't inject it yet)
for agent in data-agent training-agent eval-agent deploy-agent; do
  kubectl patch deployment -n agentic-ml "$agent" --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}}]' 2>/dev/null || true
done

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
