"""The node's agent gateway: the platform's action API as seen from a turn.

Every call is one tradera action (``namespace.action`` with a JSON body),
dispatched by the node as the agent's account inside the turn's execution
scope. The turn token authorizes it and expires with the turn.
"""

from __future__ import annotations

from typing import Any

import httpx

# Sandbox commands and agent hand-offs can legitimately take long.
CALL_TIMEOUT = httpx.Timeout(connect=10.0, read=900.0, write=60.0, pool=30.0)


class GatewayError(Exception):
    """A platform action refused or failed."""

    def __init__(self, message: str, *, code: str = "", status: int = 0) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


class DecisionDisabled(Exception):
    """The node's decision model is off (or unusable) for this turn."""


# A decision is a quick classification: the turn goes on without it rather
# than wait.
DECISION_TIMEOUT = httpx.Timeout(connect=5.0, read=12.0, write=10.0, pool=5.0)


# A timeline read is a database query: the turn goes on without it rather than wait.
TIMELINE_TIMEOUT = httpx.Timeout(connect=5.0, read=60.0, write=10.0, pool=5.0)


class Gateway:
    """Calls platform actions for one turn (async and sync flavours)."""

    def __init__(self, base_url: str, token: str, *, transport: httpx.AsyncBaseTransport | None = None,
                 sync_transport: httpx.BaseTransport | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        headers = {"Authorization": f"Bearer {token}"}
        self._client = httpx.AsyncClient(headers=headers, timeout=CALL_TIMEOUT, transport=transport)
        self._sync = httpx.Client(headers=headers, timeout=CALL_TIMEOUT, transport=sync_transport)

    @property
    def llm_base_url(self) -> str:
        """The OpenAI-compatible, metered model endpoint of the turn."""
        return self.base_url + "/llm"

    async def call(self, namespace: str, action: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        resp = await self._client.post(self.base_url + "/call", json=_payload(namespace, action, body))
        return _decode(namespace, action, resp)

    def call_sync(self, namespace: str, action: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        resp = self._sync.post(self.base_url + "/call", json=_payload(namespace, action, body))
        return _decode(namespace, action, resp)

    @property
    def decision_url(self) -> str:
        """The turn's decision endpoint: the node's decision model (e.g. Jev)."""
        return self.base_url + "/decision/evaluate"

    async def decide(self, state: Any, questions: dict[str, Any]) -> dict[str, Any]:
        """Ask the node's decision model typed questions about a state;
        returns {"answers": {...}, "usage": {...}}."""
        resp = await self._client.post(self.decision_url, json={"state": state, "questions": questions},
                                       timeout=DECISION_TIMEOUT)
        if resp.status_code == 409:
            raise DecisionDisabled(resp.text[:300])
        return _decode("decision", "evaluate", resp)

    async def timeline(self, message: dict[str, Any]) -> dict[str, Any]:
        """One MCP JSON-RPC message to the turn's space timeline (see timeline.py)."""
        resp = await self._client.post(self.base_url + "/timeline/mcp", json=message, timeout=TIMELINE_TIMEOUT)
        return _decode("timeline", "mcp", resp)

    async def aclose(self) -> None:
        await self._client.aclose()
        self._sync.close()


def _payload(namespace: str, action: str, body: dict[str, Any] | None) -> dict[str, Any]:
    return {"namespace": namespace, "action": action, "body": {k: v for k, v in (body or {}).items() if v is not None}}


def _decode(namespace: str, action: str, resp: httpx.Response) -> dict[str, Any]:
    try:
        data = resp.json()
    except ValueError:
        data = {"error": resp.text}
    if resp.status_code >= 300:
        message = data.get("error") if isinstance(data, dict) else None
        if isinstance(message, dict):
            message = message.get("message")
        raise GatewayError(f"{namespace}.{action}: {message or resp.reason_phrase}",
                           code=str(data.get("code", "")) if isinstance(data, dict) else "", status=resp.status_code)
    return data if isinstance(data, dict) else {"result": data}
