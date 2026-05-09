#!/usr/bin/env python3
"""Delete Keycloak clients to allow recreation."""
import json
import urllib.request
import urllib.parse

KEYCLOAK_URL = "http://keycloak-service.keycloak.svc.cluster.local:8080"
REALM = "demo"
AGENTS = ["data-agent", "training-agent", "eval-agent", "deploy-agent", "model-registry"]

def get_admin_token():
    data = urllib.parse.urlencode({
        'grant_type': 'password',
        'client_id': 'admin-cli',
        'username': 'admin',
        'password': 'admin'
    }).encode()
    req = urllib.request.Request(
        f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token",
        data=data
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())['access_token']

def delete_client(client_id, token):
    # Get client UUID
    req = urllib.request.Request(
        f"{KEYCLOAK_URL}/admin/realms/{REALM}/clients?clientId={client_id}",
        headers={'Authorization': f'Bearer {token}'}
    )
    with urllib.request.urlopen(req) as resp:
        clients = json.loads(resp.read())
        if not clients:
            print(f"  Client {client_id} not found")
            return

        client_uuid = clients[0]['id']

        # Delete client
        req = urllib.request.Request(
            f"{KEYCLOAK_URL}/admin/realms/{REALM}/clients/{client_uuid}",
            headers={'Authorization': f'Bearer {token}'},
            method='DELETE'
        )
        try:
            urllib.request.urlopen(req)
            print(f"✓ Deleted client: {client_id}")
        except Exception as e:
            print(f"✗ Error deleting {client_id}: {e}")

def main():
    token = get_admin_token()
    print("[delete-clients] Deleting agent clients...")

    for agent in AGENTS:
        delete_client(agent, token)

    print("[delete-clients] Done!")

if __name__ == '__main__':
    main()
