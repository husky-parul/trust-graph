"""A2A JSON-RPC 2.0 client for agent-to-agent communication."""

from typing import Any, Dict, List

import httpx


class A2AClient:

    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout

    async def send_message(
        self,
        target_url: str,
        message: str = "",
        auth_header: str = "",
        visited: List[str] | None = None,
    ) -> Dict[str, Any]:
        endpoint = f"{target_url}/message:send"

        headers = {
            "Content-Type": "application/json",
            "A2A-Version": "1.0",
        }
        if auth_header:
            headers["Authorization"] = auth_header

        metadata: Dict[str, str] = {}
        if visited:
            metadata["visited"] = ",".join(visited)

        payload: Dict[str, Any] = {
            "message": {
                "message_id": f"{target_url}-{id(self)}",
                "role": "ROLE_USER",
                "parts": [{"text": message or "run pipeline"}],
            },
        }
        if metadata:
            payload["metadata"] = metadata

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
