"""Progress: whether a long run of steps is getting anywhere.

The turn guard catches an agent repeating the very same call; it cannot see
one that keeps trying variations of something that does not work. Every few
model calls into a long run, the decision model is shown the request and the
latest steps (tool, arguments, outcome) and asked whether they move the work
forward; a confident no tells the agent to change approach.
"""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from .client import DecisionClient, probability

#: Check every this many model calls, once the run has this many tool calls.
EVERY = 8
MIN_STEPS = 6
#: The latest steps shown to the decision model.
STEPS = 10
#: Below this probability of progress the agent is told.
STUCK_BELOW = 0.3

NOTE = ("An independent check of your latest steps finds they are not moving the work forward. Stop and "
        "rethink: what is actually failing and why? Try a different approach, ask for what is missing, or "
        "finish with what you have and say what is left.")


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    return str(content)


def recent_steps(messages: list[Any]) -> list[dict[str, str]]:
    """The run's latest tool calls with their outcomes (since the person's message)."""
    results: dict[str, str] = {}
    calls: list[dict[str, Any]] = []
    for m in reversed(messages):
        if isinstance(m, HumanMessage) and not _text(m.content).startswith("[runtime note]"):
            break
        if isinstance(m, ToolMessage):
            results[m.tool_call_id] = _text(m.content)
        elif isinstance(m, AIMessage) and m.tool_calls:
            calls[:0] = m.tool_calls
    return [{"tool": c.get("name", ""),
             "args": json.dumps(c.get("args") or {}, ensure_ascii=False, default=str)[:300],
             "outcome": " ".join(results.get(c.get("id", ""), "").split())[:400]}
            for c in calls[-STEPS:]]


def due(model_calls: int, steps: int) -> bool:
    return steps >= MIN_STEPS and model_calls > 0 and model_calls % EVERY == 0


async def stuck(client: DecisionClient, request: str, steps: list[dict[str, str]]) -> bool:
    """True when the decision model is confident the steps go nowhere."""
    answers = await client.evaluate({"request": request[-3000:], "latest_steps": steps}, {"progress": {
        "type": "boolean",
        "instructions": "Do `latest_steps` make real progress toward what `request` asks for?",
        "criteria": {"true": "new information, working results or steps closer to the goal",
                     "false": "repeated failures, the same error again, or circling without new results"}}})
    p = probability(answers, "progress")
    return p is not None and p < STUCK_BELOW
