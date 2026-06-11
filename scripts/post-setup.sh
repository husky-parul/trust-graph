#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Post-Setup: Apply Custom AuthBridge Configuration ==="
echo

# Check if KAGENTI_REPO is set
if [ -z "$KAGENTI_REPO" ]; then
    echo "ERROR: KAGENTI_REPO environment variable not set"
    echo "Please set it to your kagenti-extensions clone path:"
    echo "  export KAGENTI_REPO=/path/to/kagenti-extensions"
    exit 1
fi

if [ ! -d "$KAGENTI_REPO/authbridge" ]; then
    echo "ERROR: $KAGENTI_REPO/authbridge not found"
    echo "Please ensure KAGENTI_REPO points to the kagenti-extensions repo"
    exit 1
fi

echo "Using KAGENTI_REPO: $KAGENTI_REPO"
echo

# Step 1: Build and push custom AuthBridge image (if not already present)
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

# Step 2: Update kagenti-platform-config
echo "Step 2: Updating kagenti-platform-config to use custom AuthBridge image..."
kubectl patch cm kagenti-platform-config -n kagenti-system --type=merge -p '{
  "data": {
    "images.authbridge": "ttg-registry:5000/authbridge:otel"
  }
}'

echo "✓ Platform config updated"
echo

# Step 3: Update authbridge-runtime-config
echo "Step 3: Updating authbridge-runtime-config with SPIFFE and JWT audience..."

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-runtime-config
  namespace: agentic-ml
data:
  config.yaml: |
    spiffe:
      socket: "unix:///spiffe-workload-api/spire-agent.sock"

    identity:
      type: spiffe
      jwt_audience: "http://keycloak-service.keycloak.svc:8080/realms/demo"

    listener:
      reverse_proxy_addr: ":8080"
      forward_proxy_addr: ":8082"
      transparent_proxy_addr: ":15082"
      management_addr: ":9091"

    plugins:
      - name: jwtvalidation
        config:
          issuer: "http://keycloak-service.keycloak.svc:8080/realms/demo"
          jwks_uri: "http://keycloak-service.keycloak.svc:8080/realms/demo/protocol/openid-connect/certs"
          audience: ""

      - name: tokenexchange
        config:
          token_endpoint: "http://keycloak-service.keycloak.svc:8080/realms/demo/protocol/openid-connect/token"
          client_id: ""
          client_secret: ""
EOF

echo "✓ Runtime config updated"
echo

# Step 4: Restart agent pods to pick up new image and config
echo "Step 4: Restarting agent pods..."
kubectl delete pods -n agentic-ml -l 'app in (data-agent,training-agent,eval-agent,deploy-agent)' --ignore-not-found=true

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n agentic-ml -l 'app in (data-agent,training-agent,eval-agent,deploy-agent)' --timeout=120s

echo "✓ Agent pods restarted"
echo

# Step 5: Verify AuthBridge is running with OTel
echo "Step 5: Verifying AuthBridge OTel initialization..."
sleep 3  # Give logs time to appear

OTEL_LOGS=$(kubectl logs -n agentic-ml -l app=data-agent -c authbridge-proxy --tail=100 | grep -i "otel tracing enabled" || true)

if [ -n "$OTEL_LOGS" ]; then
    echo "✓ AuthBridge OTel enabled:"
    echo "$OTEL_LOGS"
else
    echo "⚠ WARNING: No OTel initialization logs found. Check AuthBridge logs:"
    echo "  kubectl logs -n agentic-ml -l app=data-agent -c authbridge-proxy"
fi
echo

echo "=== Post-Setup Complete ==="
echo
echo "Custom AuthBridge with OTel support is now active."
echo "Run a pipeline in the UI to generate trust graph spans."
echo
echo "To access the trust-graph UI:"
echo "  kubectl port-forward -n trust-graph-ui svc/trust-graph-ui 8090:8090 --address=0.0.0.0"
echo "  Then open http://localhost:8090 in your browser"
