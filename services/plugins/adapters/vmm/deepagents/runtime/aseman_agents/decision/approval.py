"""Approvals: low-risk calls of tools that wait on a person.

An agent's ``interrupt_on`` tools pause the turn until a person approves each
call. When the admin allows it (Decision model → auto-approve), the decision
model rates each such call's risk as soon as the agent's model makes it; a
call it is confident is low-risk runs without waiting, and every other call
waits as before. ``ask_user`` (a question, not an approval) always waits.

The approval is written on the agent's message (``response_metadata``), so it
is part of the thread's checkpoint: when the turn resumes after people answer
the calls that did wait, the human-in-the-loop middleware sees the very same
set of calls needing a person.
"""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import AIMessage

from .client import DecisionClient, rungs

#: The response_metadata key listing the auto-approved tool call ids.
KEY = "aseman_auto_approved"
#: A call is approved when its probability of being low-risk is at least this.
LOW_RISK_AT = 0.95

RISK = ["low: reads, or a small change that is easily undone and plainly what was asked",
        "medium: changes or sends something, within what was asked",
        "high: destructive, irreversible, costs money, reaches people outside, or not what was asked"]


async def approve(client: DecisionClient, request: str, calls: list[dict[str, Any]]) -> list[str]:
    """The ids of the calls the decision model approves."""
    if not calls:
        return []
    questions = {f"c{i}": {"type": "score",
                           "instructions": f"How risky is it to run this call of the tool `{c.get('name', '')}` "
                                           f"with arguments {json.dumps(c.get('args') or {}, default=str)[:1500]} "
                                           "without asking a person, given `request`?",
                           "criteria": RISK}
                 for i, c in enumerate(calls)}
    answers = await client.evaluate({"request": request[-3000:]}, questions)
    if answers is None:
        return []
    return [c["id"] for i, c in enumerate(calls)
            if c.get("id") and rungs(answers, f"c{i}").get(0, 0.0) >= LOW_RISK_AT]


def mark(message: AIMessage, ids: list[str]) -> AIMessage:
    meta = {**(message.response_metadata or {}), KEY: list(ids)}
    return message.model_copy(update={"response_metadata": meta})


def approved(state: Any, call_id: str) -> bool:
    """Whether the call was approved by the decision model (read from the thread)."""
    messages = (state or {}).get("messages") if isinstance(state, dict) else getattr(state, "messages", None)
    for m in reversed(messages or []):
        if isinstance(m, AIMessage) and any(c.get("id") == call_id for c in m.tool_calls or []):
            return call_id in ((m.response_metadata or {}).get(KEY) or [])
    return False


def needs_person(request: Any) -> bool:
    """The interrupt_on ``when`` predicate: False for an approved call."""
    call_id = (getattr(request, "tool_call", None) or {}).get("id", "")
    return not (call_id and approved(getattr(request, "state", None), call_id))
