#!/usr/bin/env bash
set -euo pipefail

# Keycloak configuration for the agentic IAM demo.
# Creates realm, clients, scopes, audience mappers via REST API.
# Uses REST API instead of kcadm because kcadm has an attribute bug in KC 26.5.2.

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.agentic-ml.svc.cluster.local:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="demo"
NAMESPACE="agentic-ml"

AGENTS=(data-agent training-agent eval-agent deploy-agent model-registry)

CAPABILITY_SCOPES=(
  "read:features"
  "write:model-registry"
  "provision:gpu"
  "read:test-data"
  "write:eval-reports"
  "deploy:staging"
)

log() { echo "[configure-keycloak] $*"; }
die() { echo "[configure-keycloak] ERROR: $*" >&2; exit 1; }

# --- Get admin token ---
get_admin_token() {
  local resp
  resp=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" 2>/dev/null) || die "Failed to get admin token"
  echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# --- REST API helper ---
kc_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${KEYCLOAK_URL}/admin/realms${path}"
  local args=(-sf -X "$method" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  curl "${args[@]}" "$url" 2>/dev/null || true
}

kc_api_status() {
  local method="$1" path="$2" data="${3:-}"
  local url="${KEYCLOAK_URL}/admin/realms${path}"
  local args=(-s -o /dev/null -w "%{http_code}" -X "$method" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  curl "${args[@]}" "$url" 2>/dev/null
}

# --- Create realm ---
create_realm() {
  local status
  status=$(kc_api_status GET "/${REALM}")
  if [[ "$status" == "200" ]]; then
    log "Realm '${REALM}' already exists"
    return
  fi
  log "Creating realm '${REALM}'"
  kc_api POST "" "{\"realm\":\"${REALM}\",\"enabled\":true}"
}

# --- Create client scopes ---
create_client_scopes() {
  for scope in "${CAPABILITY_SCOPES[@]}"; do
    log "Creating client scope: ${scope}"
    kc_api POST "/${REALM}/client-scopes" \
      "{\"name\":\"${scope}\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"}}"
  done

  for agent in "${AGENTS[@]}"; do
    local aud_scope="aud:${agent}"
    log "Creating audience scope: ${aud_scope}"
    kc_api POST "/${REALM}/client-scopes" \
      "{\"name\":\"${aud_scope}\",\"protocol\":\"openid-connect\"}"

    local scope_id
    scope_id=$(kc_api GET "/${REALM}/client-scopes" | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s['name']=='${aud_scope}':
        print(s['id'])
        break
" 2>/dev/null) || continue

    if [[ -n "$scope_id" ]]; then
      kc_api POST "/${REALM}/client-scopes/${scope_id}/protocol-mappers/models" \
        "{\"name\":\"${agent}-audience-mapper\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"${agent}\",\"access.token.claim\":\"true\"}}"
    fi
  done
}

# --- Create agent clients ---
create_agent_clients() {
  for agent in "${AGENTS[@]}"; do
    log "Creating client: ${agent}"
    kc_api POST "/${REALM}/clients" \
      "{\"clientId\":\"${agent}\",\"enabled\":true,\"serviceAccountsEnabled\":true,\"clientAuthenticatorType\":\"client-jwt\",\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false}"

    local client_uuid
    client_uuid=$(kc_api GET "/${REALM}/clients?clientId=${agent}" | python3 -c "
import sys,json
clients=json.load(sys.stdin)
if clients: print(clients[0]['id'])
" 2>/dev/null) || continue

    if [[ -z "$client_uuid" ]]; then
      log "WARNING: Could not find client UUID for ${agent}"
      continue
    fi

    # Set attributes via REST API (not kcadm — kcadm has attribute bug in KC 26.5.2)
    # Never send client_id alongside client_assertion in federated-jwt exchange
    log "Setting attributes for ${agent} (${client_uuid})"
    kc_api PUT "/${REALM}/clients/${client_uuid}" \
      "{\"attributes\":{\"jwt.credential.issuer\":\"kubernetes\",\"jwt.credential.sub\":\"system:serviceaccount:${NAMESPACE}:${agent}\",\"standard.token.exchange.enabled\":\"true\"}}"

    # Add audience mapper to the client itself
    kc_api POST "/${REALM}/clients/${client_uuid}/protocol-mappers/models" \
      "{\"name\":\"${agent}-self-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"${agent}\",\"access.token.claim\":\"true\"}}"

    # Assign all capability scopes and audience scopes as defaults
    for scope in "${CAPABILITY_SCOPES[@]}"; do
      local scope_id
      scope_id=$(kc_api GET "/${REALM}/client-scopes" | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s['name']=='${scope}':
        print(s['id'])
        break
" 2>/dev/null) || continue
      if [[ -n "$scope_id" ]]; then
        kc_api PUT "/${REALM}/clients/${client_uuid}/optional-client-scopes/${scope_id}" ""
      fi
    done

    for target in "${AGENTS[@]}"; do
      local aud_scope_id
      aud_scope_id=$(kc_api GET "/${REALM}/client-scopes" | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s['name']=='aud:${target}':
        print(s['id'])
        break
" 2>/dev/null) || continue
      if [[ -n "$aud_scope_id" ]]; then
        kc_api PUT "/${REALM}/clients/${client_uuid}/default-client-scopes/${aud_scope_id}" ""
      fi
    done
  done
}

# --- Create demo-dashboard public client (for Alice login) ---
create_dashboard_client() {
  log "Creating demo-dashboard client"
  kc_api POST "/${REALM}/clients" \
    "{\"clientId\":\"demo-dashboard\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true}"
}

# --- Create alice user ---
create_demo_user() {
  log "Creating user: alice"
  kc_api POST "/${REALM}/users" \
    "{\"username\":\"alice\",\"enabled\":true,\"email\":\"alice@demo.local\",\"emailVerified\":true,\"firstName\":\"Alice\",\"lastName\":\"Demo\"}"

  local user_id
  user_id=$(kc_api GET "/${REALM}/users?username=alice" | python3 -c "
import sys,json
users=json.load(sys.stdin)
if users: print(users[0]['id'])
" 2>/dev/null) || true

  if [[ -n "$user_id" ]]; then
    kc_api PUT "/${REALM}/users/${user_id}/reset-password" \
      "{\"type\":\"password\",\"value\":\"demo\",\"temporary\":false}"
    log "Set password for alice"
  fi
}

# --- Main ---
main() {
  log "Configuring Keycloak at ${KEYCLOAK_URL}"

  TOKEN=$(get_admin_token)
  log "Got admin token"

  create_realm
  create_client_scopes
  create_agent_clients
  create_dashboard_client
  create_demo_user

  log "Keycloak configuration complete"
}

main "$@"
