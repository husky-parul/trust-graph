#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="agentic-ml"
AGENTS=(data-agent training-agent eval-agent deploy-agent model-registry)

echo "=== Post-Setup: Custom AuthBridge + Keycloak Token Exchange ==="
echo

# Default KAGENTI_REPO if not set
if [ -z "$KAGENTI_REPO" ]; then
    KAGENTI_REPO="$HOME/kagenti-extensions"
    echo "KAGENTI_REPO not set, defaulting to: $KAGENTI_REPO"
fi

if [ ! -d "$KAGENTI_REPO/authbridge" ]; then
    echo "ERROR: $KAGENTI_REPO/authbridge not found"
    echo "Please ensure KAGENTI_REPO points to the kagenti-extensions repo"
    exit 1
fi

echo "Using KAGENTI_REPO: $KAGENTI_REPO"
echo

# --- Step 1: Build and push custom AuthBridge image ---
echo "Step 1: Checking for custom AuthBridge image..."

if podman image exists localhost/authbridge:otel; then
    echo "✓ AuthBridge image already exists locally, skipping build"
else
    echo "Building custom AuthBridge image with OTel support..."
    cd "$KAGENTI_REPO/authbridge"
    podman build -t authbridge:otel -f cmd/authbridge-proxy/Dockerfile .
    echo "✓ AuthBridge image built"
fi

echo "Pushing to local registry..."
podman tag localhost/authbridge:otel 127.0.0.1:5000/authbridge:otel
podman push 127.0.0.1:5000/authbridge:otel --tls-verify=false

echo "✓ AuthBridge image available at ttg-registry:5000/authbridge:otel"
echo

# --- Step 2: Update kagenti-platform-config (patch YAML inside config.yaml) ---
echo "Step 2: Updating kagenti-platform-config to use custom AuthBridge image..."
kubectl get cm kagenti-platform-config -n kagenti-system -o json | python3 -c "
import sys, json, yaml
cm = json.load(sys.stdin)
config = yaml.safe_load(cm['data']['config.yaml'])
config['images']['authbridge'] = 'ttg-registry:5000/authbridge:otel'
config['images']['pullPolicy'] = 'Always'
cm['data']['config.yaml'] = yaml.dump(config, default_flow_style=False)
cm['data'].pop('images.authbridge', None)
for key in ['resourceVersion', 'uid', 'creationTimestamp', 'managedFields']:
    cm['metadata'].pop(key, None)
cm['metadata'].get('annotations', {}).pop('kubectl.kubernetes.io/last-applied-configuration', None)
print(json.dumps(cm))
" | kubectl apply -f -

echo "✓ Platform config updated"
echo

# --- Step 3: Add OTEL env vars to authbridge-config ---
echo "Step 3: Adding OTel env vars to authbridge-config..."
kubectl patch cm authbridge-config -n ${NAMESPACE} --type=merge -p '{
  "data": {
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://trust-graph-ui.trust-graph-ui.svc:8090",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
    "OTEL_SERVICE_NAME": "authbridge"
  }
}'
echo "✓ AuthBridge OTel config added"
echo

# --- Step 4: Update authbridge-runtime-config ---
# The new authbridge (built from current main) requires:
#   - top-level spiffe block (for in-process SPIFFE provider)
#   - identity.jwt_audience (for SVID audience when exchanging tokens)
echo "Step 4: Updating authbridge-runtime-config for new authbridge..."
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
echo "✓ Runtime config updated"
echo

# --- Step 5: Delete per-agent configs so webhook regenerates from updated runtime-config ---
echo "Step 5: Regenerating per-agent authbridge configs..."
for agent in "${AGENTS[@]}"; do
  kubectl delete configmap "authbridge-config-${agent}" -n ${NAMESPACE} --ignore-not-found 2>/dev/null || true
done
echo "✓ Per-agent configs cleared"
echo

# --- Step 6: Restart operator and agent pods ---
echo "Step 6: Restarting Kagenti operator and agent pods..."
kubectl rollout restart deployment kagenti-controller-manager -n kagenti-system
kubectl rollout status deployment kagenti-controller-manager -n kagenti-system --timeout=120s

kubectl delete pods -n ${NAMESPACE} -l "app in (data-agent,training-agent,eval-agent,deploy-agent,model-registry)" --ignore-not-found=true

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n ${NAMESPACE} -l "app in (data-agent,training-agent,eval-agent,deploy-agent)" --timeout=180s || {
    echo "WARNING: Some pods may not be ready yet. Check: kubectl get pods -n ${NAMESPACE}"
}
echo "✓ Agent pods restarted"
echo

# --- Step 7: Configure Keycloak token exchange audience scopes ---
# Keycloak 26 standard token exchange requires the target client to be in
# the aud claim of the subject token. This assigns aud:* scopes to
# trust-graph-ui so Alice's token includes SPIFFE agent audiences.
echo "Step 7: Configuring Keycloak audience scopes for token exchange..."
kubectl run kc-postsetup-$$ --image=python:3.12-slim --rm -i --restart=Never \
  -n ${NAMESPACE} \
  --env="KEYCLOAK_URL=http://keycloak-service.keycloak.svc.cluster.local:8080" \
  --command -- python3 -c "
import urllib.request, urllib.parse, json

KC = 'http://keycloak-service.keycloak.svc.cluster.local:8080'
REALM = 'demo'
NAMESPACE = '${NAMESPACE}'
AGENTS = '${AGENTS[*]}'.split()

def api(method, path, token, data=None):
    url = f'{KC}/admin/realms{path}'
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    req = urllib.request.Request(url, headers=headers, method=method)
    if data:
        req.data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read()) if resp.status == 200 else None
    except Exception:
        return None

# Get admin token
data = urllib.parse.urlencode({
    'grant_type': 'password', 'client_id': 'admin-cli',
    'username': 'admin', 'password': 'admin'
}).encode()
req = urllib.request.Request(f'{KC}/realms/master/protocol/openid-connect/token', data=data)
with urllib.request.urlopen(req) as resp:
    token = json.loads(resp.read())['access_token']

# Get trust-graph-ui client UUID
clients = api('GET', f'/{REALM}/clients?clientId=trust-graph-ui', token)
if not clients:
    print('ERROR: trust-graph-ui client not found')
    exit(1)
tgui_uuid = clients[0]['id']

# Ensure standard.token.exchange.enabled on trust-graph-ui
api('PUT', f'/{REALM}/clients/{tgui_uuid}', token,
    {'attributes': {'standard.token.exchange.enabled': 'true'}})

# Get all client scopes
all_scopes = api('GET', f'/{REALM}/client-scopes', token) or []

# Assign aud:* audience scopes to trust-graph-ui
for agent in AGENTS:
    scope_name = f'aud:{agent}'
    scope_id = next((s['id'] for s in all_scopes if s['name'] == scope_name), None)
    if scope_id:
        api('PUT', f'/{REALM}/clients/{tgui_uuid}/default-client-scopes/{scope_id}', token)
        print(f'  Assigned {scope_name} to trust-graph-ui')
    else:
        print(f'  WARNING: scope {scope_name} not found')

# Ensure SPIFFE clients have standard.token.exchange.enabled
for agent in AGENTS:
    spiffe_id = f'spiffe://localtest.me/ns/{NAMESPACE}/sa/{agent}'
    encoded = urllib.parse.quote(spiffe_id, safe='')
    agent_clients = api('GET', f'/{REALM}/clients?clientId={encoded}', token)
    if agent_clients:
        api('PUT', f'/{REALM}/clients/{agent_clients[0][\"id\"]}', token,
            {'attributes': {'standard.token.exchange.enabled': 'true',
                            'jwt.credential.issuer': 'spire-spiffe',
                            'jwt.credential.sub': spiffe_id}})
        print(f'  Enabled token exchange on {agent}')

print('Keycloak configuration complete')
" 2>/dev/null || echo "WARNING: Keycloak configuration job failed"

echo "✓ Keycloak configured"
echo

# --- Step 8: Verify ---
echo "Step 8: Verifying AuthBridge OTel initialization..."
sleep 3

OTEL_LOGS=$(kubectl logs -n ${NAMESPACE} -l app=data-agent -c authbridge-proxy --tail=20 2>/dev/null | grep -i "otel tracing enabled" || true)

if [ -n "$OTEL_LOGS" ]; then
    echo "✓ AuthBridge OTel enabled:"
    echo "$OTEL_LOGS"
else
    echo "⚠ WARNING: No OTel logs found. Check AuthBridge logs:"
    echo "  kubectl logs -n ${NAMESPACE} -l app=data-agent -c authbridge-proxy"
fi
echo

echo "=== Post-Setup Complete ==="
echo
echo "Custom AuthBridge with OTel is active. Trust graph uses AuthBridge spans."
echo
echo "To access the trust-graph UI:"
echo "  kubectl port-forward -n trust-graph-ui svc/trust-graph-ui 8090:8090 --address=0.0.0.0"
echo "  Then open http://localhost:8090 in your browser"
