#!/usr/bin/env bash
set -euo pipefail

VM_HOST="${VM_HOST:-claude@192.168.122.106}"

log() { echo "[ssh-forward] $*"; }

if [[ "${1:-}" == "--stop" ]]; then
  pkill -f "ssh.*-L.*${VM_HOST}" 2>/dev/null && log "Stopped all SSH tunnels" || log "No active tunnels"
  exit 0
fi

log "Opening SSH tunnels to ${VM_HOST}..."

ssh -f -N \
  -L 3000:127.0.0.1:9080 \
  -L 9090:127.0.0.1:8090 \
  -L 8080:127.0.0.1:7080 \
  -L 8000:127.0.0.1:8000 \
  -L 8001:127.0.0.1:8001 \
  -L 8002:127.0.0.1:8002 \
  -L 8003:127.0.0.1:8003 \
  -L 8081:127.0.0.1:8081 \
  -L 5000:127.0.0.1:5000 \
  "$VM_HOST"

log ""
log "Tunnels active (on host machine):"
log ""
printf "  %-40s → http://localhost:%s\n" "Kagenti UI (Alice login)" "3000"
printf "  %-40s → http://keycloak.localtest.me:%s\n" "Keycloak (for auth)" "8080"
printf "  %-40s → http://localhost:%s\n" "Trust Graph UI" "9090"
printf "  %-40s → http://localhost:%s\n" "Data Agent (A2A)" "8000"
printf "  %-40s → http://localhost:%s\n" "Training Agent (A2A)" "8001"
printf "  %-40s → http://localhost:%s\n" "Eval Agent (A2A)" "8002"
printf "  %-40s → http://localhost:%s\n" "Deploy Agent (A2A)" "8003"
printf "  %-40s → http://localhost:%s\n" "Model Registry (classic)" "8081"
printf "  %-40s → http://localhost:%s\n" "In-cluster registry" "5000"
log ""
log "NOTE: Port 8080 is required for Keycloak authentication."
log "If port 8080 is in use on your host, free it before running this script."
log ""
log "Stop: $0 --stop"
