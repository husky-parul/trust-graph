import json
import os
import secrets
import sqlite3
from collections import defaultdict
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak-service.keycloak.svc.cluster.local:8080")
KEYCLOAK_ADMIN = os.environ.get("KEYCLOAK_ADMIN", "admin")
KEYCLOAK_ADMIN_PASSWORD = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "demo")
NAMESPACE = os.environ.get("NAMESPACE", "agentic-ml")
BACKEND_CLIENT_ID = os.environ.get("BACKEND_CLIENT_ID", "trust-graph-ui")
BACKEND_CLIENT_SECRET = os.environ.get("BACKEND_CLIENT_SECRET", "trust-graph-ui-secret")
DB_PATH = os.environ.get("DB_PATH", "/tmp/trust_graph.db")

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

SPIFFE_PREFIX = f"spiffe://localtest.me/ns/{NAMESPACE}/sa/"
KNOWN_AGENTS = set(AGENTS)


# --- SQLite ---

def _get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db():
    conn = _get_db()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS pipeline_runs (
            run_id TEXT PRIMARY KEY,
            trace_id TEXT UNIQUE NOT NULL,
            pipeline TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS trust_spans (
            span_id TEXT PRIMARY KEY,
            trace_id TEXT NOT NULL,
            source TEXT NOT NULL,
            target TEXT NOT NULL,
            hop_kind TEXT NOT NULL,
            status TEXT NOT NULL,
            scopes TEXT,
            principal TEXT,
            timestamp TEXT NOT NULL,
            raw_attributes TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_trust_spans_trace ON trust_spans(trace_id);
    """)
    conn.commit()
    conn.close()


@app.on_event("startup")
async def _startup():
    _init_db()


# --- OTLP Receiver ---

@app.post("/v1/traces")
async def receive_traces(request: Request):
    """Receive OTLP JSON spans from AuthBridge and store trust-relevant ones in SQLite."""
    body = await request.json()
    conn = _get_db()
    stored = 0
    try:
        for rs in body.get("resourceSpans", []):
            for ss in rs.get("scopeSpans", []):
                for span in ss.get("spans", []):
                    attrs = {}
                    raw_attrs = span.get("attributes", [])
                    if isinstance(raw_attrs, dict):
                        attrs = {k: str(v) for k, v in raw_attrs.items()}
                    else:
                        for a in raw_attrs:
                            val = a.get("value", {})
                            attrs[a["key"]] = (
                                val.get("stringValue")
                                or val.get("intValue")
                                or val.get("boolValue", "")
                            )

                    if not any(k.startswith("trust.") for k in attrs):
                        continue

                    scopes_raw = attrs.get("trust.scopes", "")
                    scopes_list = [s for s in scopes_raw.split() if s] if scopes_raw else []

                    conn.execute(
                        """INSERT OR REPLACE INTO trust_spans
                           (span_id, trace_id, source, target, hop_kind, status,
                            scopes, principal, timestamp, raw_attributes)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                        (
                            span.get("spanId", ""),
                            span.get("traceId", ""),
                            _normalize_id(attrs.get("trust.source", "")),
                            _normalize_id(attrs.get("trust.target", "")),
                            attrs.get("trust.hop_kind", ""),
                            attrs.get("trust.status", "authenticated"),
                            json.dumps(scopes_list),
                            attrs.get("trust.principal", ""),
                            span.get("startTimeUnixNano", ""),
                            json.dumps(attrs),
                        ),
                    )
                    stored += 1
        conn.commit()
    finally:
        conn.close()
    return JSONResponse(content={"stored": stored})


def _normalize_id(raw: str) -> str:
    """Strip SPIFFE prefix to get short agent name."""
    if raw.startswith(SPIFFE_PREFIX):
        return raw[len(SPIFFE_PREFIX):]
    return raw

def _looks_like_uuid(s: str) -> bool:
    """Check if string looks like a UUID (8-4-4-4-12 hex pattern)."""
    import re
    return bool(re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', s, re.I))

def _extract_target(audience_str: str, source: str) -> str | None:
    """Extract the actual exchange target from the audience field.

    The audience field can be a single value (clean) or a space-separated
    list of all aud claims (noisy). We look for the requested target by
    finding SPIFFE IDs that aren't the source, falling back to short names.
    """
    parts = audience_str.split()
    if len(parts) == 1:
        return _normalize_id(parts[0])

    spiffe_targets = [
        _normalize_id(p) for p in parts
        if p.startswith("spiffe://") and _normalize_id(p) != source
    ]
    if len(spiffe_targets) == 1:
        return spiffe_targets[0]

    short_targets = [
        p for p in parts
        if not p.startswith("spiffe://") and p in KNOWN_AGENTS and p != source
    ]
    if len(short_targets) == 1:
        return short_targets[0]

    return None

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
        raw_client = event.get("clientId", "")
        details = event.get("details", {})
        raw_audience = details.get("audience", "")
        scope = details.get("scope", "")
        kc_time = event.get("time", 0)
        username = details.get("username", "")
        event_id = event.get("id", "")

        if not raw_client or not raw_audience:
            continue

        event_ids.append(event_id)
        source = _normalize_id(raw_client)
        target = _extract_target(raw_audience, source)

        if not target or target == source:
            continue

        key = (source, target)
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
                "source": source,
                "target": target,
                "scopes_granted": scopes_granted,
                "status": "authenticated",
                "hop_kind": "token_exchange",
                "call_count": 1,
                "event_ids": [event_id],
                "_first_ts": kc_time,
                "_last_ts": kc_time,
                "live": True,
            }

        if username and source == "trust-graph-ui":
            user_delegates.add((username, source))

    edges = []
    for e in edge_map.values():
        e["first_seen"] = _ts_to_iso(e.pop("_first_ts"))
        e["last_seen"] = _ts_to_iso(e.pop("_last_ts"))
        edges.append(e)

    for username, backend in user_delegates:
        edges.append({
            "source": username,
            "target": backend,
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


def build_trust_dag_from_spans(spans: list[sqlite3.Row]) -> tuple[list[dict], list[str]]:
    """Build trust DAG from AuthBridge OTel spans stored in SQLite."""
    edge_map: dict[tuple[str, str], dict] = {}
    user_delegates: set[tuple[str, str]] = set()
    span_ids: list[str] = []

    for span in spans:
        source = _normalize_id(span["source"])
        target = _normalize_id(span["target"])
        sid = span["span_id"]
        hop_kind = span["hop_kind"]
        status = span["status"]
        scopes = json.loads(span["scopes"]) if span["scopes"] else []
        principal = span["principal"]
        ts = span["timestamp"]

        if not source or not target:
            continue

        span_ids.append(sid)
        key = (source, target)
        filtered_scopes = _filter_scopes(scopes)

        if key in edge_map:
            e = edge_map[key]
            e["call_count"] += 1
            e["event_ids"].append(sid)
            for s in filtered_scopes:
                if s not in e["scopes_granted"]:
                    e["scopes_granted"].append(s)
        else:
            edge_map[key] = {
                "source": source,
                "target": target,
                "scopes_granted": filtered_scopes,
                "status": status,
                "hop_kind": hop_kind,
                "call_count": 1,
                "event_ids": [sid],
                "first_seen": ts,
                "last_seen": ts,
                "live": True,
            }

        # Create principal → backend edge (skip if principal looks like a UUID)
        if principal and source == "trust-graph-ui" and not _looks_like_uuid(principal):
            user_delegates.add((principal, source))
        elif source == "trust-graph-ui" and not principal:
            # Fallback: if no principal in span, assume alice
            user_delegates.add(("alice", source))

    edges = list(edge_map.values())

    # Add principal → backend edges
    for username, backend in user_delegates:
        edges.append({
            "source": username,
            "target": backend,
            "scopes_granted": ["*"],
            "status": "authenticated",
            "hop_kind": "principal_to_agent",
            "call_count": 1,
            "event_ids": [],
            "first_seen": "",
            "last_seen": "",
            "live": True,
        })

    # Fallback: if trust-graph-ui appears in edges but no principal edge was created, add alice → trust-graph-ui
    has_dashboard = any(e["source"] == "trust-graph-ui" or e["target"] == "trust-graph-ui" for e in edges)
    has_principal_edge = any(e["target"] == "trust-graph-ui" and e["hop_kind"] == "principal_to_agent" for e in edges)
    if has_dashboard and not has_principal_edge:
        edges.append({
            "source": "alice",
            "target": "trust-graph-ui",
            "scopes_granted": ["*"],
            "status": "authenticated",
            "hop_kind": "principal_to_agent",
            "call_count": 1,
            "event_ids": [],
            "first_seen": "",
            "last_seen": "",
            "live": True,
        })

    return edges, span_ids


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
async def trust_graph(
    event_ids_filter: str | None = Query(None, alias="event_ids"),
    trace_id: str | None = Query(None),
    run_id: str | None = Query(None),
):
    from_spans = False

    if run_id and not trace_id:
        conn = _get_db()
        row = conn.execute(
            "SELECT trace_id FROM pipeline_runs WHERE run_id = ?", (run_id,)
        ).fetchone()
        conn.close()
        if row:
            trace_id = row["trace_id"]

    if trace_id:
        conn = _get_db()
        span_rows = conn.execute(
            "SELECT * FROM trust_spans WHERE trace_id = ?", (trace_id,)
        ).fetchall()
        conn.close()

        if span_rows:
            trust_edges, event_ids = build_trust_dag_from_spans(span_rows)
            from_spans = True
        else:
            trust_edges, event_ids = [], []
            from_spans = True

    if not from_spans:
        kc_events = await get_token_exchange_events()
        if event_ids_filter:
            requested = set(event_ids_filter.split(","))
            kc_events = [e for e in kc_events if e.get("id") in requested]
        trust_edges, event_ids = build_trust_dag(kc_events)

    all_edges = list(trust_edges)

    scoped = from_spans or event_ids_filter

    if scoped:
        edge_node_ids = set()
        for edge in all_edges:
            edge_node_ids.add(edge["source"])
            edge_node_ids.add(edge["target"])

        nodes = []
        seen_ids = set()
        for nid in edge_node_ids:
            if nid in seen_ids:
                continue
            seen_ids.add(nid)
            if nid == "alice":
                nodes.append({"id": "alice", "label": "Alice", "scopes": ["*"], "type": "user"})
            elif nid == "trust-graph-ui":
                nodes.append({"id": "trust-graph-ui", "label": "Dashboard", "scopes": [], "type": "orchestrator"})
            elif nid in AGENT_SCOPES:
                nodes.append({"id": nid, "label": nid, "scopes": AGENT_SCOPES.get(nid, []), "type": NODE_TYPES.get(nid, "agent")})
            else:
                nodes.append({"id": nid, "label": nid, "scopes": [], "type": "agent"})
    else:
        nodes = []
        for agent in AGENTS:
            nodes.append({
                "id": agent,
                "label": agent,
                "scopes": AGENT_SCOPES.get(agent, []),
                "type": NODE_TYPES.get(agent, "agent"),
            })
        nodes.append({"id": "alice", "label": "Alice", "scopes": ["*"], "type": "user"})
        nodes.append({"id": "trust-graph-ui", "label": "Dashboard", "scopes": [], "type": "orchestrator"})

        seen_ids = {n["id"] for n in nodes}
        for edge in all_edges:
            for field in ("source", "target"):
                eid = edge[field]
                if eid not in seen_ids:
                    nodes.append({"id": eid, "label": eid, "scopes": [], "type": "agent"})
                    seen_ids.add(eid)

    paths = compute_paths(all_edges, nodes)
    explanations = generate_explanations(paths, nodes)

    node_ids = {n["id"] for n in nodes}
    capability_alignment = {}
    for agent in AGENTS:
        if agent in node_ids:
            capability_alignment[agent] = "ALIGNED"

    result = {
        "nodes": nodes,
        "edges": all_edges,
        "event_ids": event_ids,
        "paths": paths,
        "explanations": explanations,
        "capability_alignment": capability_alignment,
        "stats": {
            "trust_edges": len(trust_edges),
            "authenticated": sum(1 for e in all_edges if e.get("status") == "authenticated"),
            "denied": sum(1 for e in all_edges if e.get("status") == "denied"),
            "unauthenticated": sum(1 for e in all_edges if e.get("status") == "unauthenticated"),
        },
        "layers": {
            "layer1_keycloak": not from_spans,
            "layer2_authbridge_spans": from_spans,
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    if trace_id:
        result["trace_id"] = trace_id
    return result


@app.get("/api/pipeline-runs")
async def list_pipeline_runs():
    conn = _get_db()
    rows = conn.execute(
        "SELECT run_id, trace_id, pipeline, status, created_at FROM pipeline_runs ORDER BY created_at DESC LIMIT 50"
    ).fetchall()
    conn.close()
    return {
        "runs": [
            {
                "run_id": r["run_id"],
                "trace_id": r["trace_id"],
                "pipeline": json.loads(r["pipeline"]),
                "status": r["status"],
                "created_at": r["created_at"],
            }
            for r in rows
        ]
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

    run_id = str(uuid.uuid4())
    trace_id = secrets.token_hex(16)
    parent_span_id = secrets.token_hex(8)
    traceparent = f"00-{trace_id}-{parent_span_id}-01"
    steps = []

    try:
        # Get Alice's token via password grant (demo realm)
        async with httpx.AsyncClient(timeout=30) as client:
            token_resp = await client.post(
                f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
                data={
                    "grant_type": "password",
                    "client_id": BACKEND_CLIENT_ID,
                    "client_secret": BACKEND_CLIENT_SECRET,
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

            # Execute pipeline sequentially using A2A /message:send
            # Each call exchanges Alice's token for an agent-scoped token first,
            # producing Keycloak TOKEN_EXCHANGE events visible in the trust graph.
            for agent_name in pipeline:
                agent_url = f"http://{agent_name}.{NAMESPACE}.svc.cluster.local:8000"
                spiffe_id = f"spiffe://localtest.me/ns/{NAMESPACE}/sa/{agent_name}"

                start_time = time.time()

                try:
                    # Exchange Alice's token for one scoped to this agent
                    exchange_resp = await client.post(
                        f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
                        data={
                            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                            "subject_token": alice_token,
                            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                            "audience": spiffe_id,
                            "client_id": BACKEND_CLIENT_ID,
                            "client_secret": BACKEND_CLIENT_SECRET,
                        },
                    )

                    if exchange_resp.status_code != 200:
                        duration_ms = int((time.time() - start_time) * 1000)
                        steps.append({
                            "agent": agent_name,
                            "status": exchange_resp.status_code,
                            "duration_ms": duration_ms,
                            "error": f"Token exchange failed: {exchange_resp.text}",
                            "event_ids": [],
                        })
                        continue

                    agent_token = exchange_resp.json()["access_token"]

                    agent_resp = await client.post(
                        f"{agent_url}/message:send",
                        headers={
                            "Authorization": f"Bearer {agent_token}",
                            "Content-Type": "application/json",
                            "A2A-Version": "1.0",
                            "traceparent": traceparent,
                        },
                        json={
                            "message": {
                                "role": "ROLE_USER",
                                "parts": [{"text": f"Run {agent_name} pipeline step"}],
                                "message_id": str(uuid.uuid4()),
                            },
                            "configuration": {
                                "accepted_output_modes": ["text"],
                            },
                        },
                        timeout=20.0,
                    )

                    duration_ms = int((time.time() - start_time) * 1000)

                    steps.append({
                        "agent": agent_name,
                        "status": agent_resp.status_code,
                        "duration_ms": duration_ms,
                        "event_ids": [],
                    })

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

        total_duration_ms = sum(step["duration_ms"] for step in steps)
        status = "completed" if all(200 <= step["status"] < 300 for step in steps) else "failed"

        conn = _get_db()
        conn.execute(
            "INSERT OR REPLACE INTO pipeline_runs (run_id, trace_id, pipeline, status, created_at) VALUES (?, ?, ?, ?, ?)",
            (run_id, trace_id, json.dumps(pipeline), status, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
        conn.close()

        return {
            "run_id": run_id,
            "trace_id": trace_id,
            "status": status,
            "steps": steps,
            "total_duration_ms": total_duration_ms,
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
