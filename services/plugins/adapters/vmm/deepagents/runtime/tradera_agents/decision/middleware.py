"""The decision model in the agent's loop, as one middleware.

It sits outermost of the turn's own middleware. Per model call:

* first call of the turn, for a lead: the routing hint (routing.py), shown
  with every call of the turn;
* after the model answers: rate the calls that wait on a person when the
  admin allows auto-approval (approval.py).

It never changes which tools the agent sees, and it never sends the agent
back to work: the agent's own model decides how to work and when it is done.
"""

from __future__ import annotations

import logging
from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from ..guard import NOTE
from . import approval, routing
from .client import DecisionClient

log = logging.getLogger("tradera.agents.decision")


def last_request(messages: list[Any]) -> str:
    """The message the agent is working on (runtime notes aside)."""
    for m in reversed(messages):
        if isinstance(m, HumanMessage):
            text = m.text
            if not text.startswith(NOTE):
                return text
    return ""


#: Tools that put a result in front of the person (a file or image in the chat).
DELIVERY_TOOLS = {"image_generate", "file_send", "file_upload"}


def delivered(messages: list[Any]) -> list[str]:
    """What the delivery tools sent to the chat since the request (their reports)."""
    out: list[str] = []
    for m in reversed(messages):
        if isinstance(m, HumanMessage) and not m.text.startswith(NOTE):
            break
        if isinstance(m, ToolMessage) and m.name in DELIVERY_TOOLS and getattr(m, "status", "success") != "error":
            text = m.text.strip()
            if text and not text.lower().startswith("error"):
                out.append(f"{m.name}: {text[:300]}")
    out.reverse()
    return out


class DecisionMiddleware(AgentMiddleware):
    def __init__(self, client: DecisionClient, *, agents: list[Any] | None = None, lead: bool = False,
                 interrupt_on: set[str] | None = None, auto_approve: bool = False, worklog: Any = None) -> None:
        super().__init__()
        self.client = client
        self.agents = agents or []
        self.lead = lead
        self.approvable = {n for n in (interrupt_on or set()) if n != "ask_user"} if auto_approve else set()
        self.worklog = worklog
        self.hint: str | None = None

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        messages = list(request.messages)
        request_text = last_request(messages)
        if self.hint is None:
            self.hint = await routing.lead_hint(self.client, request_text, self.agents) if self.lead else ""
        if self.hint:
            request = request.override(messages=[*messages, HumanMessage(NOTE + self.hint)])
        response = await handler(request)
        if self.approvable:
            await self._approve(request_text, response)
        return response

    async def _approve(self, request_text: str, response: Any) -> None:
        result = getattr(response, "result", None)
        if not isinstance(result, list) or not self.client.enabled:
            return
        for i, m in enumerate(result):
            if not isinstance(m, AIMessage) or not m.tool_calls:
                continue
            calls = [c for c in m.tool_calls if c.get("name") in self.approvable]
            ids = await approval.approve(self.client, request_text, calls)
            if ids:
                result[i] = approval.mark(m, ids)
                names = ", ".join(c.get("name", "") for c in calls if c.get("id") in ids)
                await self._log(f"Decision · auto-approved as low risk: {names}")

    async def _log(self, text: str) -> None:
        log.info(text)
        if self.worklog is not None:
            await self.worklog.write(text)
