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
    import logging
    body = await request.json()

    # Debug: log incoming request
    total_spans_in_request = sum(
        len(ss.get("spans", []))
        for rs in body.get("resourceSpans", [])
        for ss in rs.get("scopeSpans", [])
    )
    logging.info(f"OTLP: received {total_spans_in_request} spans")

    conn = _get_db()
    stored = 0
    skipped = 0
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
                        skipped += 1
                        continue

                    # Debug: log trust attributes found
                    trust_attrs = {k: v for k, v in attrs.items() if k.startswith("trust.")}
                    logging.debug(f"OTLP: storing span with trust attrs: {trust_attrs}")

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

    # Log for debugging
    import logging
    if stored > 0:
        logging.info(f"OTLP: stored {stored} trust spans")
    if skipped > 0:
        logging.debug(f"OTLP: skipped {skipped} spans (no trust.* attributes)")

    return JSONResponse(content={"stored": stored, "skipped": skipped})


def _normalize_id(raw: str) -> str:
    """Strip SPIFFE prefix to get short agent name."""
    if raw.startswith(SPIFFE_PREFIX):
        return raw[len(SPIFFE_PREFIX):]
    return raw

def _looks_like_uuid(s: str) -> bool:
    """Check if string looks like a UUID (8-4-4-4-12 hex pattern)."""
    import re
    return bool(re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', s, re.I))

def _filter_scopes(scopes: list[str]) -> list[str]:
    return [s for s in scopes if s in CAPABILITY_SCOPES or s.startswith("aud:")]


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
    trace_id: str | None = Query(None),
    run_id: str | None = Query(None),
):
    conn = _get_db()

    if run_id and not trace_id:
        row = conn.execute(
            "SELECT trace_id FROM pipeline_runs WHERE run_id = ?", (run_id,)
        ).fetchone()
        if row:
            trace_id = row["trace_id"]

    if not trace_id:
        row = conn.execute(
            "SELECT trace_id FROM pipeline_runs ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if row:
            trace_id = row["trace_id"]

    if trace_id:
        span_rows = conn.execute(
            "SELECT * FROM trust_spans WHERE trace_id = ?", (trace_id,)
        ).fetchall()
        trust_edges, span_ids = build_trust_dag_from_spans(span_rows)
    else:
        trust_edges, span_ids = [], []

    conn.close()

    edge_node_ids = set()
    for edge in trust_edges:
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

    paths = compute_paths(trust_edges, nodes)
    explanations = generate_explanations(paths, nodes)

    node_ids = {n["id"] for n in nodes}
    capability_alignment = {}
    for agent in AGENTS:
        if agent in node_ids:
            capability_alignment[agent] = "ALIGNED"

    result = {
        "nodes": nodes,
        "edges": trust_edges,
        "event_ids": span_ids,
        "paths": paths,
        "explanations": explanations,
        "capability_alignment": capability_alignment,
        "stats": {
            "trust_edges": len(trust_edges),
            "authenticated": sum(1 for e in trust_edges if e.get("status") == "authenticated"),
            "denied": sum(1 for e in trust_edges if e.get("status") == "denied"),
            "unauthenticated": sum(1 for e in trust_edges if e.get("status") == "unauthenticated"),
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    if trace_id:
        result["trace_id"] = trace_id
    return result


@app.get("/api/debug/spans")
async def debug_spans(limit: int = 10):
    """Debug endpoint to inspect stored spans."""
    conn = _get_db()
    rows = conn.execute(
        """SELECT span_id, trace_id, source, target, hop_kind, status, scopes, principal, raw_attributes
           FROM trust_spans
           ORDER BY timestamp DESC
           LIMIT ?""",
        (limit,)
    ).fetchall()
    conn.close()

    result = []
    for r in rows:
        attrs = json.loads(r["raw_attributes"]) if r["raw_attributes"] else {}
        result.append({
            "span_id": r["span_id"][:8] + "..." if len(r["span_id"]) > 8 else r["span_id"],
            "trace_id": r["trace_id"][:8] + "..." if len(r["trace_id"]) > 8 else r["trace_id"],
            "source": r["source"],
            "target": r["target"],
            "hop_kind": r["hop_kind"],
            "status": r["status"],
            "scopes": json.loads(r["scopes"]) if r["scopes"] else [],
            "principal": r["principal"],
            "trust_attrs": {k: v for k, v in attrs.items() if k.startswith("trust.")},
        })

    return {"spans": result, "total": len(result)}


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
