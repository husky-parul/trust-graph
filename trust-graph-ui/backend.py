import json
import os
from collections import defaultdict
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak-service.keycloak.svc.cluster.local:8080")
KEYCLOAK_ADMIN = os.environ.get("KEYCLOAK_ADMIN", "admin")
KEYCLOAK_ADMIN_PASSWORD = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "demo")
JAEGER_URL = os.environ.get("JAEGER_URL", "http://jaeger.observability.svc.cluster.local:16686")
KIALI_URL = os.environ.get("KIALI_URL", "http://kiali.istio-system.svc.cluster.local:20001")
NAMESPACE = os.environ.get("NAMESPACE", "agentic-ml")

app = FastAPI(title="Trust Graph UI")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

AGENTS = ["data-agent", "training-agent", "eval-agent", "deploy-agent", "model-registry"]
AGENT_SCOPES = {
    "data-agent": ["read:features"],
    "training-agent": ["write:model-registry", "provision:gpu"],
    "eval-agent": ["read:test-data"],
    "deploy-agent": ["deploy:staging"],
    "model-registry": [],
}
NODE_TYPES = {a: "agent" for a in AGENTS}
NODE_TYPES["model-registry"] = "resource-server"

CAPABILITY_SCOPES = {
    "read:features", "write:model-registry", "provision:gpu",
    "read:test-data", "write:eval-reports", "deploy:staging",
}

def _filter_scopes(scopes: list[str]) -> list[str]:
    return [s for s in scopes if s in CAPABILITY_SCOPES]

def _ts_to_iso(epoch_ms: int) -> str:
    if not epoch_ms:
        return ""
    return datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc).isoformat()


async def get_keycloak_token() -> str:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": "admin-cli",
                "username": KEYCLOAK_ADMIN,
                "password": KEYCLOAK_ADMIN_PASSWORD,
            },
        )
        resp.raise_for_status()
        return resp.json()["access_token"]


async def get_token_exchange_events() -> list[dict]:
    try:
        token = await get_keycloak_token()
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/events",
                params={"type": "TOKEN_EXCHANGE", "max": "200"},
                headers={"Authorization": f"Bearer {token}"},
            )
            if resp.status_code != 200:
                return []
            return resp.json()
    except Exception:
        return []


def build_trust_dag(kc_events: list[dict]) -> tuple[list[dict], list[str]]:
    edge_map: dict[tuple[str, str], dict] = {}
    user_delegates: set[tuple[str, str]] = set()
    event_ids: list[str] = []

    for event in kc_events:
        client_id = event.get("clientId", "")
        details = event.get("details", {})
        audience = details.get("audience", "")
        scope = details.get("scope", "")
        kc_time = event.get("time", 0)
        username = details.get("username", "")
        event_id = event.get("id", "")

        if not client_id or not audience:
            continue

        event_ids.append(event_id)
        key = (client_id, audience)
        scopes_granted = _filter_scopes(scope.split() if scope else [])

        if key in edge_map:
            e = edge_map[key]
            e["call_count"] += 1
            e["event_ids"].append(event_id)
            if kc_time < e["_first_ts"]:
                e["_first_ts"] = kc_time
            if kc_time > e["_last_ts"]:
                e["_last_ts"] = kc_time
            for s in scopes_granted:
                if s not in e["scopes_granted"]:
                    e["scopes_granted"].append(s)
        else:
            edge_map[key] = {
                "source": client_id,
                "target": audience,
                "scopes_granted": scopes_granted,
                "status": "authenticated",
                "hop_kind": "token_exchange",
                "call_count": 1,
                "event_ids": [event_id],
                "_first_ts": kc_time,
                "_last_ts": kc_time,
                "live": True,
            }

        sub_client = details.get("subject_token_client_id", "")
        if username and sub_client == "demo-dashboard":
            user_delegates.add((username, client_id))

    edges = []
    for e in edge_map.values():
        e["first_seen"] = _ts_to_iso(e.pop("_first_ts"))
        e["last_seen"] = _ts_to_iso(e.pop("_last_ts"))
        edges.append(e)

    for username, agent in user_delegates:
        edges.append({
            "source": username,
            "target": agent,
            "scopes_granted": ["*"],
            "status": "authenticated",
            "hop_kind": "principal_to_agent",
            "call_count": 1,
            "event_ids": [],
            "first_seen": "",
            "last_seen": "",
            "live": True,
        })

    return edges, event_ids


async def get_service_spans() -> list[dict]:
    spans = []
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            for agent in AGENTS:
                resp = await client.get(
                    f"{JAEGER_URL}/api/traces",
                    params={"service": agent, "limit": "50", "lookback": "5m"},
                )
                if resp.status_code != 200:
                    continue
                for trace in resp.json().get("data", []):
                    for span in trace.get("spans", []):
                        tags = {t["key"]: t.get("value", "") for t in span.get("tags", [])}
                        spans.append({
                            "trace_id": trace.get("traceID", ""),
                            "span_id": span.get("spanID", ""),
                            "operation": span.get("operationName", ""),
                            "source": tags.get("trust.source", tags.get("source.workload", "")),
                            "destination": tags.get("trust.target", tags.get("upstream_cluster", "")),
                            "http_status": int(tags.get("http.status_code", 0)),
                            "duration_us": span.get("duration", 0),
                            "timestamp_us": span.get("startTime", 0),
                            "trust_tags": {k: v for k, v in tags.items() if k.startswith("trust.")},
                        })
    except Exception:
        pass
    return spans


async def get_kiali_edges() -> list[dict]:
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"{KIALI_URL}/kiali/api/namespaces/{NAMESPACE}/graph",
                params={"graphType": "workload", "duration": "60s"},
            )
            if resp.status_code != 200:
                return []
            graph = resp.json()
            node_map = {}
            for node in graph.get("elements", {}).get("nodes", []):
                data = node.get("data", {})
                node_map[data.get("id", "")] = data.get("workload", data.get("app", ""))
            edges = []
            for edge in graph.get("elements", {}).get("edges", []):
                data = edge.get("data", {})
                src = node_map.get(data.get("source", ""), "")
                dst = node_map.get(data.get("target", ""), "")
                if src and dst:
                    edges.append({
                        "source": src, "destination": dst, "http_status": 200,
                        "request_count": data.get("traffic", {}).get("rates", {}).get("http", 0),
                        "aggregated": True,
                    })
            return edges
    except Exception:
        return []


def _workload_matches(workload_name: str, client_id: str) -> bool:
    if not workload_name or not client_id:
        return False
    return client_id in workload_name or workload_name.startswith(client_id)


def enrich_and_detect(trust_edges: list[dict], spans: list[dict], kiali_edges: list[dict]) -> list[dict]:
    all_edges = list(trust_edges)
    network_sources = spans if spans else kiali_edges

    for edge in all_edges:
        for span in network_sources:
            src = span.get("source", "")
            dst = span.get("destination", "")
            if _workload_matches(src, edge["source"]) and _workload_matches(dst, edge["target"]):
                edge["http_status"] = span.get("http_status")
                edge["duration_us"] = span.get("duration_us")
                edge["trace_id"] = span.get("trace_id")
                if span.get("http_status") == 403:
                    edge["status"] = "denied"
                    edge["scopes_granted"] = []
                break

    authenticated_pairs = {(e["source"], e["target"]) for e in trust_edges}
    for span in network_sources:
        src = span.get("source", "")
        dst = span.get("destination", "")
        if not src or not dst:
            continue
        matched = any(
            _workload_matches(src, kc_src) and _workload_matches(dst, kc_dst)
            for kc_src, kc_dst in authenticated_pairs
        )
        if not matched and src in AGENTS and dst in AGENTS:
            all_edges.append({
                "source": src, "target": dst,
                "scopes_granted": [], "status": "unauthenticated",
                "hop_kind": "network", "call_count": 1, "event_ids": [],
                "first_seen": "", "last_seen": "",
                "timestamp": span.get("timestamp_us", 0) // 1000,
                "http_status": span.get("http_status"),
                "trace_id": span.get("trace_id"),
                "live": True,
            })

    return all_edges


def compute_paths(edges: list[dict], nodes: list[dict]) -> dict[str, list[list[str]]]:
    adj: dict[str, list[str]] = defaultdict(list)
    for e in edges:
        adj[e["source"]].append(e["target"])

    user_nodes = {n["id"] for n in nodes if n["type"] == "user"}
    paths: dict[str, list[list[str]]] = {}

    for node in nodes:
        nid = node["id"]
        if nid in user_nodes:
            continue
        node_paths = []
        stack = [(u, [u]) for u in user_nodes]
        while stack:
            current, path = stack.pop()
            if current == nid and len(path) > 1:
                node_paths.append(path)
                continue
            for neighbor in adj.get(current, []):
                if neighbor not in path:
                    stack.append((neighbor, path + [neighbor]))
        if node_paths:
            paths[nid] = node_paths

    return paths


def generate_explanations(paths: dict[str, list[list[str]]], nodes: list[dict]) -> dict[str, str]:
    node_type_map = {n["id"]: n["type"] for n in nodes}
    explanations = {}
    for nid, node_paths in paths.items():
        ntype = node_type_map.get(nid, "node")
        label = "resource" if ntype == "resource-server" else "agent"
        lines = [f"{label} {nid} was accessed because:"]
        for i, p in enumerate(node_paths, 1):
            chain = " → ".join(p)
            lines.append(f"  {i}. {chain}")
        explanations[nid] = "\n".join(lines)
    return explanations


@app.get("/api/trust-graph")
async def trust_graph():
    kc_events = await get_token_exchange_events()
    trust_edges, event_ids = build_trust_dag(kc_events)

    spans = await get_service_spans()
    kiali_edges = []
    if not spans:
        kiali_edges = await get_kiali_edges()

    all_edges = enrich_and_detect(trust_edges, spans, kiali_edges)

    nodes = []
    for agent in AGENTS:
        nodes.append({
            "id": agent,
            "label": agent,
            "scopes": AGENT_SCOPES.get(agent, []),
            "type": NODE_TYPES.get(agent, "agent"),
        })
    nodes.append({"id": "alice", "label": "alice", "scopes": ["*"], "type": "user"})

    seen_ids = {n["id"] for n in nodes}
    for edge in all_edges:
        for field in ("source", "target"):
            eid = edge[field]
            if eid not in seen_ids:
                nodes.append({"id": eid, "label": eid, "scopes": [], "type": "agent"})
                seen_ids.add(eid)

    paths = compute_paths(all_edges, nodes)
    explanations = generate_explanations(paths, nodes)

    capability_alignment = {}
    for agent in AGENTS:
        capability_alignment[agent] = "ALIGNED"

    return {
        "nodes": nodes,
        "edges": all_edges,
        "event_ids": event_ids,
        "paths": paths,
        "explanations": explanations,
        "capability_alignment": capability_alignment,
        "stats": {
            "keycloak_events": len(kc_events),
            "trust_edges": len(trust_edges),
            "network_spans": len(spans),
            "kiali_edges": len(kiali_edges),
            "authenticated": sum(1 for e in all_edges if e.get("status") == "authenticated"),
            "denied": sum(1 for e in all_edges if e.get("status") == "denied"),
            "unauthenticated": sum(1 for e in all_edges if e.get("status") == "unauthenticated"),
        },
        "layers": {
            "layer1_keycloak": True,
            "layer2_spans": bool(spans),
            "layer2_kiali": bool(kiali_edges) and not spans,
            "layer3_runtime": False,
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/agents")
async def list_agents():
    """Return list of available agents with their capabilities."""
    agents = []
    for agent_name in AGENTS:
        agents.append({
            "name": agent_name,
            "skills": [agent_name.replace("-", " ").title()],
            "capabilities": AGENT_SCOPES.get(agent_name, []),
            "url": f"http://{agent_name}.{NAMESPACE}.svc.cluster.local:8000",
        })
    return {"agents": agents}


@app.get("/api/pipelines/templates")
async def list_templates():
    """Return pre-defined pipeline templates."""
    return {
        "templates": [
            {
                "name": "Training Pipeline",
                "description": "Load data, train model, write to registry",
                "steps": ["data-agent", "training-agent", "model-registry"]
            },
            {
                "name": "Eval Pipeline",
                "description": "Load data, evaluate model, deploy",
                "steps": ["data-agent", "eval-agent", "deploy-agent"]
            },
            {
                "name": "Full ML Pipeline",
                "description": "Complete ML workflow with all agents",
                "steps": ["data-agent", "training-agent", "eval-agent", "deploy-agent"]
            },
        ]
    }


@app.post("/api/pipelines/execute")
async def execute_pipeline(request: dict):
    """Execute a pipeline by chaining agent calls with Alice's token."""
    import time
    import uuid

    pipeline = request.get("pipeline", [])
    if not pipeline:
        return {"error": "No pipeline steps provided"}, 400

    # Validate all agents exist
    for agent_name in pipeline:
        if agent_name not in AGENTS:
            return {"error": f"Unknown agent: {agent_name}"}, 400

    run_id = str(uuid.uuid4())[:8]
    steps = []

    try:
        # Get Alice's token via password grant (demo realm)
        async with httpx.AsyncClient(timeout=30) as client:
            token_resp = await client.post(
                f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
                data={
                    "grant_type": "password",
                    "client_id": "demo-dashboard",
                    "username": "alice",
                    "password": "demo",
                    "scope": "openid",
                },
            )

            if token_resp.status_code != 200:
                return {
                    "error": "Failed to obtain Alice token",
                    "details": token_resp.text,
                    "status": "failed"
                }

            alice_token = token_resp.json()["access_token"]

            # Execute pipeline sequentially
            for agent_name in pipeline:
                agent_url = f"http://{agent_name}.{NAMESPACE}.svc.cluster.local:8000"

                start_time = time.time()

                try:
                    # Call agent's /api/run-pipeline endpoint
                    agent_resp = await client.post(
                        f"{agent_url}/api/run-pipeline",
                        headers={"Authorization": f"Bearer {alice_token}"},
                        json={"task": "execute"},
                        timeout=20.0,
                    )

                    duration_ms = int((time.time() - start_time) * 1000)

                    steps.append({
                        "agent": agent_name,
                        "status": agent_resp.status_code,
                        "duration_ms": duration_ms,
                        "event_ids": [],  # Will be populated from Keycloak events
                    })

                    # Update token if agent returned a new one (for delegation chain)
                    if agent_resp.status_code == 200:
                        resp_data = agent_resp.json()
                        # Agent might return downstream results that contain tokens
                        # For now, keep using Alice's token

                except httpx.TimeoutException:
                    duration_ms = int((time.time() - start_time) * 1000)
                    steps.append({
                        "agent": agent_name,
                        "status": 408,
                        "duration_ms": duration_ms,
                        "error": "Request timeout",
                        "event_ids": [],
                    })
                except Exception as e:
                    duration_ms = int((time.time() - start_time) * 1000)
                    steps.append({
                        "agent": agent_name,
                        "status": 500,
                        "duration_ms": duration_ms,
                        "error": str(e),
                        "event_ids": [],
                    })

        # Fetch recent Keycloak events to find TOKEN_EXCHANGE events from this run
        # (In production, we'd correlate by trace ID or custom event attributes)
        kc_events = await get_token_exchange_events()
        recent_event_ids = [evt.get("id", "") for evt in kc_events[:10]]  # Last 10 events

        total_duration_ms = sum(step["duration_ms"] for step in steps)
        status = "completed" if all(200 <= step["status"] < 300 for step in steps) else "failed"

        return {
            "run_id": run_id,
            "status": status,
            "steps": steps,
            "total_duration_ms": total_duration_ms,
            "keycloak_events": recent_event_ids,
        }

    except Exception as e:
        return {
            "error": str(e),
            "status": "failed",
            "run_id": run_id,
        }


@app.get("/")
async def index():
    return FileResponse("index.html")


app.mount("/static", StaticFiles(directory="."), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8090")))
