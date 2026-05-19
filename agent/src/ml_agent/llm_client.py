"""LLM client for agent reasoning with OpenTelemetry instrumentation."""

import os
import time
from typing import Dict

LLM_MODE = os.getenv("LLM_MODE", "mock")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
AGENT_NAME = os.getenv("AGENT_NAME", "ml-agent")


async def call_llm(task_description: str, identity: Dict) -> Dict:
    """
    Generate reasoning for the given task.

    In mock mode, returns canned response immediately.
    In openai mode, calls OpenAI API (requires OPENAI_API_KEY).

    OpenTelemetry auto-instruments OpenAI SDK calls, creating spans with:
    - model name
    - token counts
    - latency

    Args:
        task_description: Description of the task to reason about
        identity: Agent identity (subject, scopes, etc.)

    Returns:
        Dict with reasoning, mode, and metadata
    """
    if LLM_MODE == "mock":
        return _mock_llm_call(task_description, identity)
    elif LLM_MODE == "openai":
        return await _openai_llm_call(task_description, identity)
    else:
        return {
            "reasoning": f"[{AGENT_NAME}] Unknown LLM_MODE: {LLM_MODE}",
            "mode": "error",
            "model": None,
        }


def _mock_llm_call(task_description: str, identity: Dict) -> Dict:
    """Mock LLM reasoning for demo purposes."""
    time.sleep(0.05)  # Simulate latency

    subject = identity.get("subject", "unknown")
    scopes = identity.get("scopes", "")

    reasoning = (
        f"[{AGENT_NAME}] Mock LLM reasoning:\n"
        f"Task: {task_description}\n"
        f"Acting as: {subject}\n"
        f"Scopes: {scopes}\n"
        f"Decision: Proceeding with downstream delegation"
    )

    return {
        "reasoning": reasoning,
        "mode": "mock",
        "model": "mock-gpt-4o",
        "latency_ms": 50,
    }


async def _openai_llm_call(task_description: str, identity: Dict) -> Dict:
    """Real OpenAI LLM call with auto-instrumentation."""
    if not OPENAI_API_KEY or OPENAI_API_KEY == "mock-key-for-demo":
        return {
            "reasoning": f"[{AGENT_NAME}] OpenAI mode requires valid OPENAI_API_KEY",
            "mode": "error",
            "model": None,
        }

    try:
        from openai import AsyncOpenAI

        client = AsyncOpenAI(api_key=OPENAI_API_KEY)

        subject = identity.get("subject", "unknown")
        scopes = identity.get("scopes", "")

        prompt = (
            f"You are {AGENT_NAME}, an agent in a multi-agent ML pipeline.\n"
            f"Task: {task_description}\n"
            f"You are acting as: {subject}\n"
            f"You have scopes: {scopes}\n\n"
            f"Provide brief reasoning about how you will handle this task. "
            f"Mention what you'll delegate downstream if applicable."
        )

        start = time.time()
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": prompt}],
            max_tokens=200,
        )
        latency_ms = int((time.time() - start) * 1000)

        reasoning = response.choices[0].message.content or ""

        return {
            "reasoning": reasoning,
            "mode": "openai",
            "model": response.model,
            "latency_ms": latency_ms,
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
        }
