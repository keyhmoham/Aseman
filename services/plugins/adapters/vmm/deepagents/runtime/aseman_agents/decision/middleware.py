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

log = logging.getLogger("aseman.agents.decision")


def last_request(messages: list[Any]) -> str:
    """The message the agent is working on (runtime notes aside)."""
    for m in reversed(messages):
        if isinstance(m, HumanMessage):
            text = m.text
            if not text.startswith(NOTE):
                return text
    return ""


#: Native delivery tools (Code Mode-off fallback) and the Code Mode paths that
#: put a result in front of the person (file/image in chat, or desk card/page).
DELIVERY_TOOLS = {"image_generate", "file_send", "file_upload", "ui_present", "appui_create", "appui_publish",
                  "proxy_create"}
DELIVERY_PLATFORM_PATHS = tuple(f"/platform/{name}" for name in sorted(DELIVERY_TOOLS))


def _codemode_delivery_label(code: str) -> str | None:
    """If Code Mode JS calls a delivery platform path, return a short label."""
    for path in DELIVERY_PLATFORM_PATHS:
        if path in code:
            return path.removeprefix("/platform/")
    return None


def delivered(messages: list[Any]) -> list[str]:
    """What delivery tools put in front of the person since the request.

    Counts native ``file_send`` / ``appui_create`` / … results and successful
    ``codemode_execute`` calls whose code hit a ``/platform/{delivery}`` path.
    """
    # tool_call_id → code string for codemode_execute calls in this window.
    code_by_id: dict[str, str] = {}
    out: list[str] = []
    window: list[Any] = []
    for m in reversed(messages):
        if isinstance(m, HumanMessage) and not m.text.startswith(NOTE):
            break
        window.append(m)
    window.reverse()
    for m in window:
        if isinstance(m, AIMessage):
            for call in m.tool_calls or []:
                if call.get("name") == "codemode_execute":
                    code_by_id[str(call.get("id") or "")] = str((call.get("args") or {}).get("code") or "")
        if not isinstance(m, ToolMessage) or getattr(m, "status", "success") == "error":
            continue
        text = m.text.strip()
        if not text or text.lower().startswith("error") or text.lower().startswith("code mode error"):
            continue
        if m.name in DELIVERY_TOOLS:
            out.append(f"{m.name}: {text[:300]}")
            continue
        if m.name == "codemode_execute":
            label = _codemode_delivery_label(code_by_id.get(m.tool_call_id or "", ""))
            if label:
                out.append(f"{label}: {text[:300]}")
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
