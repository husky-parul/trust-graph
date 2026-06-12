#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="agentic-ml"
AGENTS=(data-agent training-agent eval-agent deploy-agent model-registry)

echo "=== Post-Setup: Keycloak Token Exchange + OTel Verification ==="
echo

# --- Step 1: Configure Keycloak token exchange audience scopes ---
# Keycloak 26 standard token exchange requires the target client to be in
# the aud claim of the subject token. This assigns aud:* scopes to
# trust-graph-ui so Alice's token includes SPIFFE agent audiences.
echo "Step 1: Configuring Keycloak audience scopes for token exchange..."
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

# --- Step 2: Verify AuthBridge OTel ---
echo "Step 2: Verifying AuthBridge OTel initialization..."
sleep 3

OTEL_LOGS=$(kubectl logs -n ${NAMESPACE} -l app=data-agent -c authbridge-proxy --tail=20 2>/dev/null | grep -i "otel\|exporting spans" || true)

if [ -n "$OTEL_LOGS" ]; then
    echo "✓ AuthBridge OTel active:"
    echo "$OTEL_LOGS" | head -5
else
    echo "⚠ No OTel logs yet (spans are emitted on first request)."
    echo "  Run a pipeline to trigger AuthBridge span export."
fi
echo

# --- Step 3: Verify custom image ---
echo "Step 3: Verifying AuthBridge image..."
CURRENT_IMG=$(kubectl get pod -n ${NAMESPACE} -l app=data-agent -o jsonpath='{.items[0].spec.containers[?(@.name=="authbridge-proxy")].image}' 2>/dev/null)
echo "  Image: ${CURRENT_IMG}"
if echo "$CURRENT_IMG" | grep -q "authbridge:otel"; then
    echo "✓ Custom AuthBridge with OTel tracing"
else
    echo "⚠ WARNING: Running stock AuthBridge image — OTel spans will not be emitted"
    echo "  Ensure authbridge:otel was built (scripts/build-images.sh) and re-run setup"
fi
echo

echo "=== Post-Setup Complete ==="
echo
echo "To access the trust-graph UI:"
echo "  kubectl port-forward -n trust-graph-ui svc/trust-graph-ui 8090:8090 --address=0.0.0.0"
echo "  Then open http://localhost:8090 in your browser"
