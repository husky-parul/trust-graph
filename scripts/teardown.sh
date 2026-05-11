#!/usr/bin/env bash
set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-kagenti}"

log() { echo "[teardown] $*"; }

if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  log "Kind cluster '${KIND_CLUSTER}' not found — nothing to do"
  exit 0
fi

log "Deleting Kind cluster '${KIND_CLUSTER}'..."
kind delete cluster --name "${KIND_CLUSTER}"
log "Cluster deleted"
