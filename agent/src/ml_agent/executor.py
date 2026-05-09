import base64
import json
import os

import httpx
from a2a.server.agent_execution.agent_executor import AgentExecutor
from a2a.server.agent_execution.context import RequestContext
from a2a.server.events.event_queue import EventQueue
from a2a.server.tasks.task_updater import TaskUpdater
from a2a.types import Part

AGENT_NAME = os.environ.get("AGENT_NAME", "ml-agent")
MODEL_REGISTRY_URL = os.environ.get("MODEL_REGISTRY_URL", "")
DOWNSTREAM = os.environ.get("DOWNSTREAM", "")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


def _read_file(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return ""


def _decode_jwt(token: str) -> dict | None:
    try:
        payload = token.split(".")[1]
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None


def _get_identity(auth_header: str) -> dict:
    sa_token = _read_file(SA_TOKEN_PATH)
    namespace = _read_file(SA_NAMESPACE_PATH)
    sa_claims = _decode_jwt(sa_token) if sa_token else None

    sa_name = ""
    if sa_claims:
        if "sub" in sa_claims:
            sa_name = sa_claims["sub"]
        elif "kubernetes.io" in sa_claims:
            k8s = sa_claims["kubernetes.io"]
            sa_name = f"system:serviceaccount:{k8s.get('namespace', '?')}:{k8s.get('serviceaccount', {}).get('name', '?')}"

    incoming_claims = None
    if auth_header and auth_header.startswith("Bearer "):
        incoming_claims = _decode_jwt(auth_header[7:])

    subject = ""
    actor = ""
    scopes = ""
    audience = ""
    if incoming_claims:
        subject = incoming_claims.get("sub", "")
        act = incoming_claims.get("act")
        if isinstance(act, dict):
            actor = act.get("sub", "")
        scopes = incoming_claims.get("scope", "")
        aud = incoming_claims.get("aud", "")
        audience = ", ".join(aud) if isinstance(aud, list) else str(aud)

    return {
        "agent_name": AGENT_NAME,
        "namespace": namespace,
        "service_account": sa_name,
        "subject": subject,
        "actor": actor,
        "scopes": scopes,
        "audience": audience,
    }


async def _call_downstream(url: str, auth_header: str) -> dict:
    headers = {}
    if auth_header:
        headers["Authorization"] = auth_header
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(url, headers=headers, json={})
            return {"url": url, "status": resp.status_code, "response": resp.json()}
    except Exception as e:
        return {"url": url, "status": 0, "error": str(e)}


async def _try_model_registry_write(auth_header: str) -> dict | None:
    if not MODEL_REGISTRY_URL:
        return None
    headers = {"Content-Type": "application/json"}
    if auth_header:
        headers["Authorization"] = auth_header
    body = {
        "model_name": "test-model",
        "version": "1.0",
        "written_by": AGENT_NAME,
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{MODEL_REGISTRY_URL}/write", headers=headers, json=body
            )
            return {
                "status": resp.status_code,
                "response": resp.json(),
                "allowed": resp.status_code == 200,
            }
    except Exception as e:
        return {"status": 0, "error": str(e), "allowed": False}


class MLAgentExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue):
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)

        auth_header = ""
        if context.call_context:
            state = context.call_context.state or {}
            headers = state.get("headers", {})
            if isinstance(headers, dict):
                auth_header = headers.get("authorization", "")
            elif hasattr(headers, "get"):
                auth_header = headers.get("authorization", "")

        identity = _get_identity(auth_header)

        result = {"agent": identity, "downstream_results": [], "model_registry_test": None}

        if DOWNSTREAM:
            for url in DOWNSTREAM.split(","):
                url = url.strip()
                if url:
                    dr = await _call_downstream(url + "/api/run-pipeline", auth_header)
                    result["downstream_results"].append(dr)

        if MODEL_REGISTRY_URL:
            result["model_registry_test"] = await _try_model_registry_write(auth_header)

        await updater.add_artifact([Part(text=json.dumps(result, indent=2))])
        await updater.complete()

    async def cancel(self, context: RequestContext, event_queue: EventQueue):
        pass
