"""Discover agents in the cluster by querying AgentCard CRs from the K8s API."""

import os
import time
from typing import Dict, List

import httpx

AGENT_NAME = os.environ.get("AGENT_NAME", "")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
K8S_API = "https://kubernetes.default.svc"
CACHE_TTL = 60

_cache: List[Dict] = []
_cache_time: float = 0


def _read_file(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return ""


async def discover_agents() -> List[Dict]:
    """Return available agents from Agent CRs, excluding self. Cached for 60s."""
    global _cache, _cache_time

    if _cache and (time.time() - _cache_time) < CACHE_TTL:
        return _cache

    token = _read_file(SA_TOKEN_PATH)
    namespace = _read_file(SA_NAMESPACE_PATH)
    if not token or not namespace:
        return []

    headers = {"Authorization": f"Bearer {token}"}

    try:
        ssl_context = httpx.create_ssl_context()
        if os.path.exists(SA_CA_PATH):
            ssl_context.load_verify_locations(SA_CA_PATH)

        async with httpx.AsyncClient(verify=ssl_context, timeout=5) as client:
            # Try AgentCard CRs first (populated by controller)
            url = f"{K8S_API}/apis/agent.kagenti.dev/v1alpha1/namespaces/{namespace}/agentcards"
            resp = await client.get(url, headers=headers)
            resp.raise_for_status()
            agents = _parse_agentcards(resp.json(), namespace)

            # Fall back to Agent CRs if no AgentCards have card data
            if not agents:
                url = f"{K8S_API}/apis/agent.kagenti.dev/v1alpha1/namespaces/{namespace}/agents"
                resp = await client.get(url, headers=headers)
                if resp.status_code == 200:
                    agents = _parse_agent_crs(resp.json(), namespace)

            # Fall back to Services with kagenti.io/type=agent label
            if not agents:
                url = f"{K8S_API}/api/v1/namespaces/{namespace}/services?labelSelector=kagenti.io/type=agent"
                resp = await client.get(url, headers=headers)
                resp.raise_for_status()
                agents = _parse_services(resp.json(), namespace)
    except Exception:
        return _cache or []

    _cache = agents
    _cache_time = time.time()
    return agents


def _parse_agentcards(data: Dict, namespace: str) -> List[Dict]:
    agents = []
    for item in data.get("items", []):
        card = item.get("status", {}).get("card", {})
        if not card:
            continue
        name = card.get("name", "")
        if not name or name == AGENT_NAME:
            continue
        agents.append({
            "name": name,
            "url": card.get("url", ""),
            "description": card.get("description", ""),
            "skills": [s.get("name", "") for s in card.get("skills", [])],
        })
    return agents


def _parse_services(data: Dict, namespace: str) -> List[Dict]:
    agents = []
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name or name == AGENT_NAME:
            continue
        port = 8000
        for p in item.get("spec", {}).get("ports", []):
            port = p.get("port", 8000)
            break
        agents.append({
            "name": name,
            "url": f"http://{name}.{namespace}.svc.cluster.local:{port}",
            "description": "",
            "skills": [],
        })
    return agents


def _parse_agent_crs(data: Dict, namespace: str) -> List[Dict]:
    agents = []
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name or name == AGENT_NAME:
            continue
        phase = item.get("status", {}).get("deploymentStatus", {}).get("phase", "")
        if phase != "Ready":
            continue
        spec = item.get("spec", {})
        port = 8000
        for sp in spec.get("servicePorts", []):
            port = sp.get("port", 8000)
            break
        agents.append({
            "name": name,
            "url": f"http://{name}.{namespace}.svc.cluster.local:{port}",
            "description": spec.get("description", ""),
            "skills": [],
        })
    return agents
