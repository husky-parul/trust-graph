#!/usr/bin/env python3
"""Configure Keycloak for the agentic IAM demo."""
import json
import urllib.request
import urllib.parse
import sys

KEYCLOAK_URL = "http://keycloak-service.keycloak.svc.cluster.local:8080"
REALM = "demo"
NAMESPACE = "agentic-ml"
AGENTS = ["data-agent", "training-agent", "eval-agent", "deploy-agent", "model-registry"]
CAPABILITY_SCOPES = [
    "read:features",
    "write:model-registry",
    "provision:gpu",
    "read:test-data",
    "write:eval-reports",
    "deploy:staging"
]

def get_admin_token():
    """Get admin access token."""
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

def kc_api(method, path, token, data=None):
    """Call Keycloak admin API."""
    url = f"{KEYCLOAK_URL}/admin/realms{path}"
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    req = urllib.request.Request(url, headers=headers, method=method)
    if data:
        req.data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read()) if resp.status == 200 else None
    except urllib.error.HTTPError as e:
        if e.code == 409:  # Conflict - already exists
            return None
        raise

def main():
    print("[configure-keycloak] Getting admin token...")
    token = get_admin_token()

    # Create realm
    print(f"[configure-keycloak] Creating realm '{REALM}'...")
    kc_api('POST', '', token, {'realm': REALM, 'enabled': True})

    # Create capability scopes
    for scope in CAPABILITY_SCOPES:
        print(f"[configure-keycloak] Creating scope: {scope}")
        kc_api('POST', f'/{REALM}/client-scopes', token, {
            'name': scope,
            'protocol': 'openid-connect',
            'attributes': {'include.in.token.scope': 'true'}
        })

    # Create audience scopes with mappers
    for agent in AGENTS:
        aud_scope = f"aud:{agent}"
        print(f"[configure-keycloak] Creating audience scope: {aud_scope}")
        kc_api('POST', f'/{REALM}/client-scopes', token, {
            'name': aud_scope,
            'protocol': 'openid-connect'
        })

        # Get scope ID and add mapper
        scopes = kc_api('GET', f'/{REALM}/client-scopes', token)
        scope_id = next((s['id'] for s in scopes if s['name'] == aud_scope), None)
        if scope_id:
            kc_api('POST', f'/{REALM}/client-scopes/{scope_id}/protocol-mappers/models', token, {
                'name': f'{agent}-audience-mapper',
                'protocol': 'openid-connect',
                'protocolMapper': 'oidc-audience-mapper',
                'config': {
                    'included.client.audience': agent,
                    'access.token.claim': 'true'
                }
            })

    # Create agent clients with federated-jwt
    for agent in AGENTS:
        print(f"[configure-keycloak] Creating client: {agent}")
        kc_api('POST', f'/{REALM}/clients', token, {
            'clientId': agent,
            'enabled': True,
            'serviceAccountsEnabled': True,
            'clientAuthenticatorType': 'client-secret',  # Use client-secret for demo
            'standardFlowEnabled': False,
            'directAccessGrantsEnabled': False,
            'secret': 'demo-secret'
        })

        # Get client UUID
        clients = kc_api('GET', f'/{REALM}/clients?clientId={agent}', token)
        if not clients:
            continue
        client_uuid = clients[0]['id']

        # Set federated-jwt attributes
        print(f"[configure-keycloak] Setting federated-jwt attributes for {agent}")
        kc_api('PUT', f'/{REALM}/clients/{client_uuid}', token, {
            'attributes': {
                'jwt.credential.issuer': 'https://kubernetes.default.svc.cluster.local',
                'jwt.credential.sub': f'system:serviceaccount:{NAMESPACE}:{agent}',
                'jwt.credential.certificate.jwks.url': 'https://kubernetes.default.svc.cluster.local:443/openid/v1/jwks',
                'standard.token.exchange.enabled': 'true'
            }
        })

        # Add self-audience mapper
        kc_api('POST', f'/{REALM}/clients/{client_uuid}/protocol-mappers/models', token, {
            'name': f'{agent}-self-audience',
            'protocol': 'openid-connect',
            'protocolMapper': 'oidc-audience-mapper',
            'config': {
                'included.client.audience': agent,
                'access.token.claim': 'true'
            }
        })

        # Assign scopes
        all_scopes = kc_api('GET', f'/{REALM}/client-scopes', token)
        for scope in CAPABILITY_SCOPES:
            scope_id = next((s['id'] for s in all_scopes if s['name'] == scope), None)
            if scope_id:
                kc_api('PUT', f'/{REALM}/clients/{client_uuid}/optional-client-scopes/{scope_id}', token, {})

        for target in AGENTS:
            aud_scope_id = next((s['id'] for s in all_scopes if s['name'] == f'aud:{target}'), None)
            if aud_scope_id:
                kc_api('PUT', f'/{REALM}/clients/{client_uuid}/default-client-scopes/{aud_scope_id}', token, {})

    # Create demo-dashboard client
    print("[configure-keycloak] Creating demo-dashboard client")
    kc_api('POST', f'/{REALM}/clients', token, {
        'clientId': 'demo-dashboard',
        'enabled': True,
        'publicClient': True,
        'standardFlowEnabled': True,
        'directAccessGrantsEnabled': True
    })

    # Create alice user
    print("[configure-keycloak] Creating user: alice")
    kc_api('POST', f'/{REALM}/users', token, {
        'username': 'alice',
        'enabled': True,
        'email': 'alice@example.com',
        'emailVerified': True
    })

    users = kc_api('GET', f'/{REALM}/users?username=alice', token)
    if users:
        user_id = users[0]['id']
        kc_api('PUT', f'/{REALM}/users/{user_id}/reset-password', token, {
            'type': 'password',
            'value': 'demo',
            'temporary': False
        })
        print("[configure-keycloak] Set password for alice")

    # Enable TOKEN_EXCHANGE events
    print("[configure-keycloak] Enabling TOKEN_EXCHANGE events")
    kc_api('PUT', f'/{REALM}', token, {
        'eventsEnabled': True,
        'eventsListeners': ['jboss-logging'],
        'enabledEventTypes': ['TOKEN_EXCHANGE']
    })

    print("[configure-keycloak] Configuration complete!")

if __name__ == '__main__':
    main()
