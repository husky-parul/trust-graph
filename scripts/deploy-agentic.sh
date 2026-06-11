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

# 1b. Register agentic-ml with Kagenti (creates Keycloak client secrets via oauth-secret job)
log "Registering agentic-ml as Kagenti agent namespace..."
# Label namespace for Helm adoption (idempotent)
kubectl label ns agentic-ml app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
kubectl annotate ns agentic-ml meta.helm.sh/release-name=kagenti meta.helm.sh/release-namespace=kagenti-system --overwrite 2>/dev/null || true
# Delete completed oauth-secret job so Helm can recreate it with updated namespaces
kubectl delete job kagenti-agent-oauth-secret-job -n kagenti-system --ignore-not-found 2>/dev/null || true
KAGENTI_CHART="${KAGENTI_REPO}/charts/kagenti"
CURRENT_NS=$(helm get values kagenti -n kagenti-system -o json 2>/dev/null | python3 -c "import sys,json; ns=json.load(sys.stdin).get('agentNamespaces',['team1','team2']); print(','.join(ns))" 2>/dev/null || echo "team1,team2")
if ! echo "$CURRENT_NS" | grep -q 'agentic-ml'; then
  CURRENT_NS="${CURRENT_NS},agentic-ml"
fi
helm upgrade kagenti "${KAGENTI_CHART}" -n kagenti-system --reuse-values \
  --set "agentNamespaces={${CURRENT_NS}}"
log "Waiting for oauth-secret job..."
kubectl wait --for=condition=complete job/kagenti-agent-oauth-secret-job -n kagenti-system --timeout=120s || {
  log "WARNING: oauth-secret job did not complete. Pods may fail to mount secrets."
}

# 2. AuthBridge routes ConfigMap
kubectl apply -f "${REPO_ROOT}/k8s/agentic/authbridge-routes.yaml"

# 2b. Sidecar ConfigMaps (envoy, spiffe-helper, authbridge-config)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/sidecar-configmaps.yaml"

# 2c. Environments ConfigMap (Keycloak credentials for client-registration sidecar)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/environments-configmap.yaml"

# 3. Services
kubectl apply -f "${REPO_ROOT}/k8s/agentic/services.yaml"

# 4. Deployments (webhook injects AuthBridge sidecars based on kagenti.io/type label)
log "Applying Deployments..."
kubectl apply -f "${REPO_ROOT}/k8s/agentic/deployments.yaml"

# 4b. AgentRuntime CRs (tell operator to manage these Deployments)
log "Applying AgentRuntime CRs..."
kubectl apply -f "${REPO_ROOT}/k8s/agentic/agentruntimes.yaml"

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

# 7. Check AgentRuntimes and AgentCards
log "Checking AgentCards..."
kubectl get agentcards -n agentic-ml 2>/dev/null || log "AgentCard CRDs not yet available (operator may still be syncing)"

log "Agentic namespace deployed"
kubectl get pods -n agentic-ml
