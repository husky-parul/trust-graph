"""A2A JSON-RPC 2.0 client for agent-to-agent communication."""

import httpx
from typing import Dict, Any


class A2AClient:
    """Minimal A2A client for sending JSON-RPC 2.0 requests to other agents."""

    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout

    async def send_message(
        self,
        target_url: str,
        message: str = "",
        auth_header: str = "",
    ) -> Dict[str, Any]:
        """
        Send A2A JSON-RPC 2.0 request to target agent.

        Args:
            target_url: Base URL of target agent (e.g., http://training-agent:8000)
            message: Text message to send (optional, can be empty for pipeline triggers)
            auth_header: Authorization header to forward (traceparent auto-propagated by httpx instrumentation)

        Returns:
            Dict with status, response, or error
        """
        endpoint = f"{target_url}/api/run-pipeline"

        headers = {"Content-Type": "application/json"}
        if auth_header:
            headers["Authorization"] = auth_header

        # A2A JSON-RPC 2.0 request format
        # For now, minimal payload - agents auto-process based on their skills
        payload = {
            "jsonrpc": "2.0",
            "method": "run",
            "params": {"message": message} if message else {},
            "id": 1,
        }

        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.post(endpoint, headers=headers, json=payload)
                return {
                    "url": target_url,
                    "status": resp.status_code,
                    "response": resp.json() if resp.status_code == 200 else resp.text,
                }
        except httpx.TimeoutException:
            return {
                "url": target_url,
                "status": 0,
                "error": "Request timeout",
            }
        except Exception as e:
            return {
                "url": target_url,
                "status": 0,
                "error": str(e),
            }
