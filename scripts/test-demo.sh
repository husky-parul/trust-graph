#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
TEST_POD="test-runner-$$"

log()  { echo "[test] $*"; }
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }

cleanup() {
  kubectl delete pod "$TEST_POD" --force --grace-period=0 &>/dev/null || true
}
trap cleanup EXIT

# --- Spin up a curl pod for in-cluster requests ---
log "Starting test runner pod..."
kubectl run "$TEST_POD" --image=curlimages/curl --restart=Never --command -- sleep 300 &>/dev/null
kubectl wait --for=condition=Ready "pod/$TEST_POD" --timeout=30s &>/dev/null

kc() {
  kubectl exec "$TEST_POD" -- curl -s "$@" 2>/dev/null
}

kc_status() {
  kubectl exec "$TEST_POD" -- curl -s -o /dev/null -w "%{http_code}" "$@" 2>/dev/null
}

# ===========================================================================
# CLASSIC NAMESPACE TESTS
# ===========================================================================
log "=== Classic Namespace Tests ==="

# Test 1: Break 1 — all agents share the same service account
log "Test 1: Shared identity (Break 1)"
sa1=$(kubectl get deploy -n classic-ml data-agent -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
sa2=$(kubectl get deploy -n classic-ml training-agent -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)

if [[ -n "$sa1" && "$sa1" == "$sa2" ]]; then
  pass "Both agents share service account: ${sa1}"
else
  fail "Agents have different service accounts: data=${sa1} training=${sa2}"
fi

# Test 2: Break 2 — model-registry accepts writes without auth
log "Test 2: Over-permissioned writes (Break 2)"
write_result=$(kc -X POST -H "Content-Type: application/json" \
  -d '{"model_name":"break2-test","version":"1.0","written_by":"data-agent"}' \
  http://model-registry.classic-ml.svc.cluster.local:8080/write)
write_status=$(echo "$write_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

if [[ "$write_status" == "written" ]]; then
  pass "model-registry accepted unauthenticated write — Break 2 confirmed"
else
  fail "Expected write to succeed in classic mode, got: ${write_result}"
fi

# ===========================================================================
# AGENTIC NAMESPACE TESTS
# ===========================================================================
log ""
log "=== Agentic Namespace Tests ==="

# Test 3: Agents have individual service accounts
log "Test 3: Individual agent identities"
sa_data=$(kubectl get deploy -n agentic-ml data-agent -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
sa_train=$(kubectl get deploy -n agentic-ml training-agent -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)

if [[ -n "$sa_data" && -n "$sa_train" && "$sa_data" != "$sa_train" ]]; then
  pass "Agents have distinct service accounts: data=${sa_data} training=${sa_train}"
else
  fail "Agents should have distinct service accounts: data=${sa_data} training=${sa_train}"
fi

# Test 4: Model-registry rejects writes without proper scope
log "Test 4: Scope enforcement on model-registry"
reject_status=$(kc_status -X POST -H "Content-Type: application/json" \
  -d '{"model_name":"unauth-test","version":"1.0","written_by":"nobody"}' \
  http://model-registry.agentic-ml.svc.cluster.local:8080/write)

if [[ "$reject_status" == "401" || "$reject_status" == "403" ]]; then
  pass "Model-registry rejected unauthenticated write (HTTP ${reject_status})"
else
  fail "Expected 401/403, got HTTP ${reject_status}"
fi

# Test 5: A2A agent card endpoint
log "Test 5: A2A agent card endpoint"
agent_card=$(kc http://data-agent.agentic-ml.svc.cluster.local:8000/.well-known/agent-card.json)
card_name=$(echo "$agent_card" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

if [[ "$card_name" == "data-agent" ]]; then
  pass "data-agent serves valid A2A agent card"
else
  fail "Expected agent card with name 'data-agent', got: ${card_name}"
fi

# Test 6: Trust graph UI is running and returns nodes
log "Test 6: Trust graph UI API"
tg_result=$(kc http://trust-graph-ui.trust-graph-ui.svc.cluster.local:8090/api/trust-graph)
tg_nodes=$(echo "$tg_result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('nodes',[])))" 2>/dev/null || echo "0")

if [[ "$tg_nodes" -gt 0 ]]; then
  pass "Trust graph API returns ${tg_nodes} nodes"
else
  fail "Trust graph API returned no nodes"
fi

# Test 7: Keycloak demo realm exists
log "Test 7: Keycloak demo realm"
kc_status_code=$(kc_status http://keycloak-service.keycloak.svc.cluster.local:8080/realms/demo)

if [[ "$kc_status_code" == "200" ]]; then
  pass "Keycloak demo realm exists"
else
  fail "Keycloak demo realm not found (HTTP ${kc_status_code})"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
log ""
log "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
