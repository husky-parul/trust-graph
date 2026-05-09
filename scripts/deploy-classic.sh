#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[deploy-classic] $*"; }

log "Deploying classic ML pipeline (shared identity, no auth)..."

kubectl apply -f "${REPO_ROOT}/k8s/classic/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/classic/rbac.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/classic/deployments.yaml"

log "Waiting for pods..."
kubectl wait --for=condition=ready pod -l app -n classic-ml --timeout=120s || true

log "Classic namespace deployed"
kubectl get pods -n classic-ml
