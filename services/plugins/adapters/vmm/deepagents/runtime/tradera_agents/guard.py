"""Keeping a turn from running away.

A turn is bounded by the number of model calls it makes, not by LangGraph's
recursion limit: every model call is several graph steps (the model, the
tools and each middleware hook), so a step limit is a poor proxy and ends the
turn with an error and no answer. Instead:

* the agent is told when it repeats the same tool call, or keeps polling for
  tasks, that the result will not change and it should change approach;
* a few calls before its budget it is told to wrap up;
* its last call has no tools: it writes its final answer, so the turn ends
  with the result and what is left rather than an error.

Every tool call the agent makes runs: the guard advises, it never refuses a
call. The graph's recursion limit stays the deep agents default, far above
any budget, as a backstop only.
"""

from __future__ import annotations

import json
import os
from collections import Counter
from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage, HumanMessage

#: Model calls a turn may make when the agent sets no max_turns.
DEFAULT_MAX_CALLS = 150
#: The same tool call (name and arguments) this many times in a turn is a loop.
REPEATS = 3
#: Polling tools: this many calls in a turn is enough.
POLL_TOOLS = frozenset({"check_tasks", "read_room", "read_direct_messages"})
POLLS = 6
#: Calls before the budget at which the agent is told to wrap up.
WARN_BEFORE = 5

NOTE = "[runtime note] "


def max_calls(max_turns: int) -> int:
    if max_turns > 0:
        return max_turns
    try:
        return max(5, int(os.environ.get("TRADERA_MAX_MODEL_CALLS", "") or DEFAULT_MAX_CALLS))
    except ValueError:
        return DEFAULT_MAX_CALLS


def signature(call: dict[str, Any]) -> str:
    """A tool call's name and arguments: the same signature is the same call."""
    return call.get("name", "") + json.dumps(call.get("args") or {}, sort_keys=True, default=str)


def _run_calls(messages: list[Any]) -> list[dict[str, Any]]:
    """The tool calls the agent made since the last message from a person."""
    calls: list[dict[str, Any]] = []
    for m in reversed(messages):
        # The runtime's own notes in the history are not a new request.
        if isinstance(m, HumanMessage) and not m.text.startswith(NOTE):
            break
        if isinstance(m, AIMessage) and m.tool_calls:
            calls[:0] = m.tool_calls
    return calls


def notes(messages: list[Any], calls_made: int, budget: int) -> list[str]:
    """What the agent should be told before its next step."""
    out: list[str] = []
    calls = _run_calls(messages)
    counts = Counter(signature(c) for c in calls)
    repeated = sorted({c.get("name", "") for c in calls if counts[signature(c)] >= REPEATS})
    if repeated:
        out.append(f"You called {', '.join(repeated)} with the same arguments {REPEATS} or more times this turn. "
                   "Its result will not change: use what you already have, try a different approach, or finish "
                   "with what you have and say what is left.")
    polls = Counter(c.get("name", "") for c in calls if c.get("name") in POLL_TOOLS)
    polled = sorted(name for name, n in polls.items() if n >= POLLS)
    if polled:
        out.append(f"You have called {', '.join(polled)} many times this turn. Do not poll in a loop: continue "
                   "other work, use wait_tasks once, or finish and report what is still running.")
    left = budget - calls_made
    if 0 < left <= WARN_BEFORE:
        out.append(f"You have {left} steps left in this turn. Wrap up now: finish the essential part and write "
                   "your final answer.")
    return out


class TurnGuard(AgentMiddleware):
    """Bounds a turn by model calls and steers the agent out of loops."""

    def __init__(self, budget: int) -> None:
        super().__init__()
        self.budget = budget
        self.calls = 0
        # Model calls the agent was told it was looping before (repeats,
        # polling): the agent's learning takes such a turn up sooner.
        self.loops = 0

    @property
    def exhausted(self) -> bool:
        return self.calls >= self.budget

    def _request(self, request: Any) -> Any:
        self.calls += 1
        if self.exhausted:
            note = ("This turn has used all its steps: no more tools can run. Write your final answer now: what "
                    "you did, the results and where they are, and what is left to do.")
            return request.override(messages=[*request.messages, HumanMessage(NOTE + note)], tool_choice="none")
        found = notes(request.messages, self.calls, self.budget)
        if not found:
            return request
        if any("steps left" not in n for n in found):
            self.loops += 1
        return request.override(messages=[*request.messages, HumanMessage(NOTE + "\n".join(found))])

    def _response(self, response: Any) -> Any:
        if not self.exhausted:
            return response
        # The last call may not run tools, whatever the model answered.
        result = getattr(response, "result", None)
        if isinstance(result, list):
            for i, m in enumerate(result):
                if isinstance(m, AIMessage) and m.tool_calls:
                    result[i] = m.model_copy(update={
                        "tool_calls": [], "invalid_tool_calls": [],
                        "content": m.text.strip() or "I ran out of steps for this turn before finishing. "
                                                     "Ask me to continue and I will pick up where I left off.",
                    })
        return response

    def wrap_model_call(self, request: Any, handler: Any) -> Any:
        return self._response(handler(self._request(request)))

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        return self._response(await handler(self._request(request)))
