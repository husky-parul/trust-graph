"""LLM client for agent reasoning with OpenTelemetry instrumentation."""

import json
import os
import time
from typing import Dict, List

LLM_MODE = os.getenv("LLM_MODE", "mock")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
AGENT_NAME = os.getenv("AGENT_NAME", "ml-agent")

PIPELINE_ORDER = ["data-agent", "training-agent", "eval-agent", "deploy-agent"]


async def call_llm(
    task_description: str,
    identity: Dict,
    available_agents: List[Dict] | None = None,
) -> Dict:
    if LLM_MODE == "mock":
        return _mock_llm_call(task_description, identity, available_agents or [])
    elif LLM_MODE == "openai":
        return await _openai_llm_call(task_description, identity, available_agents or [])
    else:
        return {
            "reasoning": f"[{AGENT_NAME}] Unknown LLM_MODE: {LLM_MODE}",
            "mode": "error",
            "model": None,
            "delegates_to": [],
        }


def _mock_llm_call(
    task_description: str, identity: Dict, available_agents: List[Dict]
) -> Dict:
    time.sleep(0.05)

    subject = identity.get("subject", "unknown")
    scopes = identity.get("scopes", "")

    # Pick the next agent in the pipeline order
    delegates_to: List[str] = []
    try:
        idx = PIPELINE_ORDER.index(AGENT_NAME)
        next_agent = PIPELINE_ORDER[idx + 1] if idx + 1 < len(PIPELINE_ORDER) else None
    except ValueError:
        next_agent = None

    available_names = {a["name"] for a in available_agents}
    if next_agent and next_agent in available_names:
        delegates_to = [next_agent]

    agent_list = ", ".join(a["name"] for a in available_agents) if available_agents else "none"
    reasoning = (
        f"[{AGENT_NAME}] Mock LLM reasoning:\n"
        f"Task: {task_description}\n"
        f"Acting as: {subject}\n"
        f"Scopes: {scopes}\n"
        f"Available agents: {agent_list}\n"
        f"Decision: Delegate to {delegates_to if delegates_to else 'nobody (end of chain)'}"
    )

    return {
        "reasoning": reasoning,
        "mode": "mock",
        "model": "mock-gpt-4o",
        "latency_ms": 50,
        "delegates_to": delegates_to,
    }


async def _openai_llm_call(
    task_description: str, identity: Dict, available_agents: List[Dict]
) -> Dict:
    if not OPENAI_API_KEY or OPENAI_API_KEY == "mock-key-for-demo":
        return {
            "reasoning": f"[{AGENT_NAME}] OpenAI mode requires valid OPENAI_API_KEY",
            "mode": "error",
            "model": None,
            "delegates_to": [],
        }

    try:
        from openai import AsyncOpenAI

        client = AsyncOpenAI(api_key=OPENAI_API_KEY)

        subject = identity.get("subject", "unknown")
        scopes = identity.get("scopes", "")

        agents_desc = "\n".join(
            f"- {a['name']}: {a['description']} (skills: {', '.join(a['skills'])})"
            for a in available_agents
        ) if available_agents else "No other agents available."

        prompt = (
            f"You are {AGENT_NAME}, an agent in a multi-agent ML pipeline.\n"
            f"Task: {task_description}\n"
            f"You are acting as: {subject}\n"
            f"You have scopes: {scopes}\n\n"
            f"Available agents you can delegate to:\n{agents_desc}\n\n"
            f"Respond with JSON: {{\"reasoning\": \"...\", \"delegates_to\": [\"agent-name\", ...]}}\n"
            f"Only delegate to agents whose skills are needed for your task. "
            f"Return an empty list if no delegation is needed."
        )

        start = time.time()
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": prompt}],
            max_tokens=200,
        )
        latency_ms = int((time.time() - start) * 1000)

        raw = response.choices[0].message.content or ""
        delegates_to: List[str] = []
        reasoning = raw
        try:
            parsed = json.loads(raw)
            reasoning = parsed.get("reasoning", raw)
            delegates_to = parsed.get("delegates_to", [])
        except json.JSONDecodeError:
            pass

        return {
            "reasoning": reasoning,
            "mode": "openai",
            "model": response.model,
            "latency_ms": latency_ms,
            "delegates_to": delegates_to,
            "usage": {
                "prompt_tokens": response.usage.prompt_tokens,
                "completion_tokens": response.usage.completion_tokens,
                "total_tokens": response.usage.total_tokens,
            },
        }
    except Exception as e:
        return {
            "reasoning": f"[{AGENT_NAME}] OpenAI call failed: {str(e)}",
            "mode": "error",
            "model": None,
            "delegates_to": [],
        }
