#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/ttg-portfwd.pids"

log() { echo "[port-forward] $*"; }

stop_all() {
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null && log "Stopped PID $pid" || true
    done < "$PID_FILE"
    rm -f "$PID_FILE"
    log "All port-forwards stopped"
  else
    log "No active port-forwards found"
  fi
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_all
  exit 0
fi

# Kill any existing forwards first
stop_all 2>/dev/null || true

declare -A FORWARDS=(
  ["8090"]="trust-graph-ui/svc/trust-graph-ui:8090"
  ["8000"]="agentic-ml/svc/data-agent:8000"
  ["8001"]="agentic-ml/svc/training-agent:8000"
  ["8002"]="agentic-ml/svc/eval-agent:8000"
  ["8003"]="agentic-ml/svc/deploy-agent:8000"
  ["8080"]="agentic-ml/svc/model-registry:8080"
  ["8081"]="classic-ml/svc/model-registry:8080"
  ["5000"]="cr-system/svc/registry:5000"
)

declare -A LABELS=(
  ["8090"]="Trust Graph UI"
  ["8000"]="Data Agent (A2A)"
  ["8001"]="Training Agent (A2A)"
  ["8002"]="Eval Agent (A2A)"
  ["8003"]="Deploy Agent (A2A)"
  ["8080"]="Model Registry (agentic, scope-checked)"
  ["8081"]="Model Registry (classic, no auth)"
  ["5000"]="In-cluster registry"
)

> "$PID_FILE"

for local_port in "${!FORWARDS[@]}"; do
  target="${FORWARDS[$local_port]}"
  ns="${target%%/*}"
  rest="${target#*/}"
  resource="${rest%%:*}"
  remote_port="${rest##*:}"

  kubectl port-forward -n "$ns" "$resource" "${local_port}:${remote_port}" &>/dev/null &
  pid=$!
  echo "$pid" >> "$PID_FILE"
done

sleep 2

log ""
log "Port-forwards active:"
log ""
for local_port in $(echo "${!FORWARDS[@]}" | tr ' ' '\n' | sort -n); do
  label="${LABELS[$local_port]}"
  printf "  %-40s → http://localhost:%s\n" "$label" "$local_port"
done
log ""
log "Stop all: $0 --stop"
log "PIDs saved to ${PID_FILE}"
