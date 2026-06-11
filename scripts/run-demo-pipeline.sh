#!/usr/bin/env bash
set -euo pipefail

# Triggers a real ML pipeline flow through AuthBridge sidecars:
#   Alice token → data-agent → (AuthBridge token exchange) → downstream agents
#
# Runs entirely inside the cluster (kubectl exec into the agent pod).
# Real TOKEN_EXCHANGE events appear in Keycloak.

NAMESPACE="${NAMESPACE:-agentic-ml}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
ENTRY_AGENT="${ENTRY_AGENT:-data-agent}"

log() { echo "[demo-pipeline] $*"; }
err() { echo "[demo-pipeline] ERROR: $*" >&2; }

log "Running pipeline via $ENTRY_AGENT..."
kubectl exec -n "$NAMESPACE" "deploy/$ENTRY_AGENT" -c agent -- \
    python3 -c "
import httpx, json, sys, os

KC = 'http://keycloak-service.$KC_NAMESPACE.svc.cluster.local:8080'
ENTRY = 'http://$ENTRY_AGENT.$NAMESPACE.svc.cluster.local:8000'

r = httpx.post(KC + '/realms/demo/protocol/openid-connect/token',
    data={'grant_type': 'password', 'client_id': 'demo-dashboard',
          'username': 'alice', 'password': 'demo'}, timeout=10)
d = r.json()
if 'access_token' not in d:
    print('Alice login failed: ' + str(d.get('error_description', d)), file=sys.stderr)
    sys.exit(1)
token = d['access_token']
print('Alice logged in', flush=True)

print('Sending A2A request to $ENTRY_AGENT...', flush=True)
try:
    r = httpx.post(ENTRY + '/message:send',
        headers={
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token,
            'A2A-Version': '1.0',
        },
        json={
            'message': {
                'message_id': 'demo-pipeline-1',
                'role': 'ROLE_USER',
                'parts': [{'text': 'Run the ML pipeline: load data, train model, evaluate, deploy'}],
            },
            'metadata': {'visited': ''},
        },
        timeout=60)
    print('Response (HTTP ' + str(r.status_code) + '):', flush=True)
    try:
        print(json.dumps(r.json(), indent=2))
    except Exception:
        print(r.text)
except Exception as e:
    print('Request failed: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1

echo

# Check for TOKEN_EXCHANGE events
log "Checking Keycloak for TOKEN_EXCHANGE events..."
sleep 2

# kcadm needs auth first
kubectl exec -n "$KC_NAMESPACE" keycloak-0 -- \
    /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin 2>/dev/null

EVENTS=$(kubectl exec -n "$KC_NAMESPACE" keycloak-0 -- \
    /opt/keycloak/bin/kcadm.sh get events -r demo \
    -q 'type=TOKEN_EXCHANGE' --offset 0 --limit 20 2>/dev/null)

EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$EVENT_COUNT" -gt 0 ]]; then
    log "Found $EVENT_COUNT TOKEN_EXCHANGE events:"
    echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    details = e.get('details', {})
    src = e.get('clientId', '?')
    aud = details.get('audience', '?')
    scope = details.get('token_exchange_scope', details.get('scope', '?'))
    print(f'  {src} -> {aud}  [scopes: {scope}]')
" 2>/dev/null || echo "$EVENTS"
else
    log "No TOKEN_EXCHANGE events found."
    log "AuthBridge may not be performing token exchange on outbound calls."
fi

echo
log "Done."
