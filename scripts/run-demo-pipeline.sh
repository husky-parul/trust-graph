#!/usr/bin/env bash
set -euo pipefail

# Simulates the ML pipeline token exchange flow:
#   Alice → data-agent → training-agent → model-registry
#                       → eval-agent     → deploy-agent
#
# Each arrow is a Keycloak TOKEN_EXCHANGE event that the trust graph UI picks up.
# Run this script to populate the trust graph with edges.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[demo-pipeline] $*"; }

PIPELINE_SCRIPT='
import httpx, json, base64, asyncio, sys

KC = "http://keycloak-service.keycloak.svc.cluster.local:8080"
AGENTS = ["data-agent", "training-agent", "eval-agent", "deploy-agent", "model-registry"]

def decode_jwt(token):
    payload = token.split(".")[1]
    payload += "=" * (4 - len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))

async def main():
    async with httpx.AsyncClient(timeout=10) as c:
        # Get admin token + client secrets
        r = await c.post(f"{KC}/realms/master/protocol/openid-connect/token",
            data={"grant_type":"password","client_id":"admin-cli","username":"admin","password":"admin"})
        admin_token = r.json()["access_token"]
        h = {"Authorization": f"Bearer {admin_token}"}

        secrets = {}
        for agent in AGENTS:
            r = await c.get(f"{KC}/admin/realms/demo/clients?clientId={agent}", headers=h)
            uuid = r.json()[0]["id"]
            r = await c.get(f"{KC}/admin/realms/demo/clients/{uuid}/client-secret", headers=h)
            secrets[agent] = r.json()["value"]

        # Alice logs in
        r = await c.post(f"{KC}/realms/demo/protocol/openid-connect/token",
            data={"grant_type":"password","client_id":"demo-dashboard","username":"alice","password":"demo"})
        d = r.json()
        if "access_token" not in d:
            print(f"Alice login failed: {d.get(\"error_description\", d)}", file=sys.stderr)
            sys.exit(1)
        alice_token = d["access_token"]
        print("Alice logged in")

        async def exchange(src, src_token, dst, scopes):
            r = await c.post(f"{KC}/realms/demo/protocol/openid-connect/token", data={
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "client_id": src, "client_secret": secrets[src],
                "subject_token": src_token,
                "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "audience": dst, "scope": scopes
            })
            d = r.json()
            if "access_token" in d:
                claims = decode_jwt(d["access_token"])
                print(f"  {src} -> {dst}  [scopes: {scopes}]")
                return d["access_token"]
            else:
                print(f"  {src} -> {dst}  FAILED: {d.get(\"error_description\", d)}", file=sys.stderr)
                return None

        # ML pipeline flow
        print("Running pipeline token exchanges:")

        # data-agent gets token from Alice, calls training-agent
        t1 = await exchange("data-agent", alice_token, "training-agent", "write:model-registry provision:gpu")

        # training-agent writes to model-registry
        if t1:
            await exchange("training-agent", t1, "model-registry", "write:model-registry")

        # data-agent also calls eval-agent
        t2 = await exchange("data-agent", alice_token, "eval-agent", "read:test-data")

        # eval-agent triggers deploy-agent
        if t2:
            await exchange("eval-agent", t2, "deploy-agent", "deploy:staging")

        print()
        print("Done. Check the trust graph UI for edges.")

asyncio.run(main())
'

log "Running ML pipeline token exchange flow..."
kubectl exec -n trust-graph-ui deploy/trust-graph-ui -- python3 -c "$PIPELINE_SCRIPT" 2>&1
