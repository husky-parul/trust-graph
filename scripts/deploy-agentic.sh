#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KAGENTI_REPO="${KAGENTI_REPO:-}"
if [[ -z "$KAGENTI_REPO" ]]; then
  if [[ -d "${REPO_ROOT}/../kagenti" ]]; then
    KAGENTI_REPO="${REPO_ROOT}/../kagenti"
  fi
fi

log() { echo "[deploy-agentic] $*"; }

log "Deploying agentic ML pipeline (individual identities, AuthBridge, scope narrowing)..."

# 0. Replace stock Keycloak with custom SPI image (act-claim injection + scope narrowing)
log "Patching Keycloak with agentic SPI image..."
kubectl patch statefulset -n keycloak keycloak --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"ttg-registry:5000/keycloak-agentic-spi:latest\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Always\"}
]"
# Add KC_FEATURES if not already present
KC_FEATURES="client-auth-federated:v1,spiffe:v1,kubernetes-service-accounts,token-exchange,token-exchange-standard"
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

# 1c. Patch operator to include spire-agent-socket volumeMount fix (missing in 0.3.0-alpha.1)
FIXED_OPERATOR_IMG="ttg-registry:5000/kagenti-operator:fixed"
if curl -sf "http://127.0.0.1:5000/v2/kagenti-operator/tags/list" | grep -q '"fixed"'; then
  CURRENT_OPERATOR_IMG=$(kubectl get deploy kagenti-controller-manager -n kagenti-system -o jsonpath='{.spec.template.spec.containers[0].image}')
  if [[ "$CURRENT_OPERATOR_IMG" != "$FIXED_OPERATOR_IMG" ]]; then
    log "Patching operator with spire-agent-socket mount fix..."
    kubectl set image deployment/kagenti-controller-manager -n kagenti-system "manager=${FIXED_OPERATOR_IMG}"
    kubectl patch deployment kagenti-controller-manager -n kagenti-system --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'
    kubectl rollout status deployment/kagenti-controller-manager -n kagenti-system --timeout=120s
  fi
fi

# 1d. Patch platform-config to use custom AuthBridge image with OTel tracing
if curl -sf "http://127.0.0.1:5000/v2/authbridge/tags/list" | grep -q '"otel"'; then
  log "Patching platform-config to use authbridge:otel..."
  kubectl get cm kagenti-platform-config -n kagenti-system -o json | python3 -c "
import sys, json, yaml
cm = json.load(sys.stdin)
config = yaml.safe_load(cm['data']['config.yaml'])
config['images']['authbridge'] = 'ttg-registry:5000/authbridge:otel'
config['images']['pullPolicy'] = 'Always'
cm['data']['config.yaml'] = yaml.dump(config, default_flow_style=False)
for key in ['resourceVersion', 'uid', 'creationTimestamp', 'managedFields']:
    cm['metadata'].pop(key, None)
cm['metadata'].get('annotations', {}).pop('kubectl.kubernetes.io/last-applied-configuration', None)
print(json.dumps(cm))
" | kubectl apply -f -
  kubectl rollout restart deployment kagenti-controller-manager -n kagenti-system
  kubectl rollout status deployment kagenti-controller-manager -n kagenti-system --timeout=120s
else
  log "WARNING: authbridge:otel not in registry — using stock image (no OTel tracing)"
fi

# 2. AuthBridge routes ConfigMap
kubectl apply -f "${REPO_ROOT}/k8s/agentic/authbridge-routes.yaml"

# 2b. Sidecar ConfigMaps (envoy, spiffe-helper, authbridge-config)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/sidecar-configmaps.yaml"

# 2c. Environments ConfigMap (Keycloak credentials for client-registration sidecar)
kubectl apply -f "${REPO_ROOT}/k8s/agentic/environments-configmap.yaml"

# 3. Services
kubectl apply -f "${REPO_ROOT}/k8s/agentic/services.yaml"

# 3b. Patch authbridge-runtime-config for demo realm + custom authbridge format
log "Patching authbridge-runtime-config for demo realm..."
kubectl apply -f - <<'AUTHCFG'
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-runtime-config
  namespace: agentic-ml
data:
  config.yaml: |
    spiffe:
      socket: "unix:///spiffe-workload-api/spire-agent.sock"
      mirror_files: true
      mirror_dir: "/opt"
    pipeline:
      inbound:
        plugins:
          - name: jwt-validation
            config:
              issuer: "http://keycloak.localtest.me:8080/realms/demo"
              keycloak_url: "http://keycloak-service.keycloak.svc:8080"
              keycloak_realm: "demo"
      outbound:
        plugins:
          - name: token-exchange
            config:
              keycloak_url: "http://keycloak-service.keycloak.svc:8080"
              keycloak_realm: "demo"
              default_policy: "exchange"
              identity:
                type: "spiffe"
                jwt_audience: "http://keycloak-service.keycloak.svc:8080/realms/demo"
              routes:
                file: "/etc/authproxy/routes.yaml"
AUTHCFG

# 3d. Delete stale per-agent ConfigMaps so webhook regenerates them from updated namespace config
log "Cleaning stale per-agent authbridge ConfigMaps..."
kubectl delete configmap -n agentic-ml -l kagenti.io/per-agent-config=true --ignore-not-found 2>/dev/null || true
for agent in data-agent training-agent eval-agent deploy-agent model-registry; do
  kubectl delete configmap "authbridge-config-${agent}" -n agentic-ml --ignore-not-found 2>/dev/null || true
done

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
