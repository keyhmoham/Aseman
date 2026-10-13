"""The decision model in the agent's loop, as one middleware.

It sits outermost of the turn's own middleware, so it sees every tool the
agent has and its extra model call (the completion check) still passes the
turn guard's budget. Per model call:

* first call of the turn: choose the tools (tools.py) and, for a lead, the
  routing hint (routing.py), together;
* every call: show the chosen tools (plus the agent's working tools and any
  tool it used), with one note naming the others and the hint;
* now and then in a long run: the progress check (progress.py);
* after the model answers: rate the calls that wait on a person when the
  admin allows auto-approval (approval.py);
* on the final answer: the completion check (completion.py), once a turn.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from langchain.agents.middleware import AgentMiddleware, hook_config
from langchain_core.messages import AIMessage, HumanMessage

from . import approval, completion, progress, routing
from . import tools as choosing
from .client import DecisionClient

log = logging.getLogger("tradera.agents.decision")

NOTE = "[runtime note] "


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    return str(content)


def last_request(messages: list[Any]) -> str:
    """The message the agent is working on (runtime notes aside)."""
    for m in reversed(messages):
        if isinstance(m, HumanMessage):
            text = _text(m.content)
            if not text.startswith(NOTE):
                return text
    return ""


class DecisionMiddleware(AgentMiddleware):
    def __init__(self, client: DecisionClient, *, guard: Any = None, agents: list[Any] | None = None,
                 lead: bool = False, interrupt_on: set[str] | None = None, auto_approve: bool = False,
                 worklog: Any = None) -> None:
        super().__init__()
        self.client = client
        self.guard = guard
        self.agents = agents or []
        self.lead = lead
        self.approvable = {n for n in (interrupt_on or set()) if n != "ask_user"} if auto_approve else set()
        self.worklog = worklog
        self.chosen: set[str] | None = None
        self.hint = ""
        self.calls = 0
        self._decided = False
        self._completion_checked = False

    # --- before each model call ----------------------------------------------

    async def _decide_once(self, request_text: str, tools: list[Any]) -> None:
        if self._decided:
            return
        self._decided = True
        chosen, hint = await asyncio.gather(
            choosing.shortlist(self.client, request_text, tools),
            routing.lead_hint(self.client, request_text, self.agents) if self.lead else _nothing(),
        )
        self.chosen, self.hint = chosen, hint or ""
        if chosen is not None:
            log.info("decision: %d chosen of %d tools", len(chosen), len(tools))

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        self.calls += 1
        messages = list(request.messages)
        tools = list(request.tools or [])
        request_text = last_request(messages)
        await self._decide_once(request_text, tools)
        notes: list[str] = []
        shown = tools
        if self.chosen is not None:
            used = {c.get("name") for m in messages if isinstance(m, AIMessage) for c in m.tool_calls or []}
            keep = choosing.PINNED | self.chosen | used
            shown = [t for t in tools if choosing.tool_name(t) in keep]
            hidden = [choosing.tool_name(t) for t in tools if choosing.tool_name(t) not in keep]
            if hidden:
                notes.append(choosing.hidden_note(hidden))
        if self.hint:
            notes.append(self.hint)
        steps = progress.recent_steps(messages)
        if self.client.enabled and progress.due(self.calls, len(steps)) and \
                await progress.stuck(self.client, request_text, steps):
            notes.append(progress.NOTE)
            await self._log("Decision · progress check: the latest steps are not moving the work forward")
        overrides: dict[str, Any] = {}
        if len(shown) != len(tools):
            overrides["tools"] = shown
        if notes:
            overrides["messages"] = [*messages, HumanMessage(NOTE + "\n".join(notes))]
        if overrides:
            request = request.override(**overrides)
        response = await handler(request)
        if self.approvable:
            await self._approve(request_text, response)
        return response

    # --- after the model answers ---------------------------------------------

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

    @hook_config(can_jump_to=["model"])
    async def aafter_model(self, state: Any, runtime: Any) -> dict[str, Any] | None:
        if self._completion_checked or not self.client.enabled:
            return None
        if self.guard is not None and getattr(self.guard, "budget", 0) - getattr(self.guard, "calls", 0) < 2:
            return None  # no steps left to act on the check
        messages = state.get("messages") or []
        last = messages[-1] if messages else None
        if not isinstance(last, AIMessage) or last.tool_calls:
            return None
        self._completion_checked = True
        if not await completion.incomplete(self.client, last_request(messages), _text(last.content)):
            return None
        await self._log("Decision · completion check: the answer does not deliver the request yet; continuing")
        return {"messages": [HumanMessage(NOTE + completion.NOTE)], "jump_to": "model"}

    async def _log(self, text: str) -> None:
        log.info(text)
        if self.worklog is not None:
            await self.worklog.write(text)


async def _nothing() -> str:
    return ""
