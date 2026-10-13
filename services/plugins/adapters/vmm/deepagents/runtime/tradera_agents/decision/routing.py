"""Routing: which of the space's agents fits a piece of work best.

* ``best_agent`` resolves a hand-off the agent addressed to nobody in
  particular (a role, a misspelt name): the decision model picks among the
  space's agents by their descriptions, and only a confident pick is taken;
* ``lead_hint`` gives a lead, once per turn, the agent that fits the request
  best — or that it should do the work itself — as a hint its model weighs.
"""

from __future__ import annotations

import re
from typing import Any

from .client import DecisionClient, choice

#: A pick is taken only at or above this probability.
CONFIDENT = 0.6
SELF = "yourself"
_KEY = re.compile(r"[^A-Za-z0-9_-]+")


def _options(agents: list[Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for m in agents:
        key = _KEY.sub("-", m.name).strip("-")[:64] or m.bot_id
        if key and key != SELF and key not in out:
            out[key] = m
    return out


async def best_agent(client: DecisionClient | None, task: str, agents: list[Any]) -> Any | None:
    """The agent to hand a task to, or None when no pick is confident."""
    options = _options(agents)
    if client is None or not options or not task.strip():
        return None
    answers = await client.evaluate({"task": task[:4000]}, {"agent": {
        "type": "choice", "instructions": "Which agent should take `task`?",
        "criteria": {k: (m.description or m.name)[:300] for k, m in options.items()}}})
    picked = choice(answers, "agent")
    if picked is None or picked[1] < CONFIDENT:
        return None
    return options.get(picked[0])


async def lead_hint(client: DecisionClient | None, request: str, agents: list[Any]) -> str:
    """One line for a lead: the agent that fits the request, or ''."""
    options = _options(agents)
    if client is None or len(options) < 2 or not request.strip():
        return ""
    criteria = {k: (m.description or m.name)[:300] for k, m in options.items()}
    criteria[SELF] = "the lead itself: small or coordinating work, or nothing a specialist is better at"
    answers = await client.evaluate({"request": request[-4000:]}, {"route": {
        "type": "choice", "instructions": "Who is best suited to do the work `request` asks for?",
        "criteria": criteria}})
    picked = choice(answers, "route")
    if picked is None or picked[0] == SELF or picked[1] < CONFIDENT:
        return ""
    return (f"Routing hint: of the space's agents, {options[picked[0]].name} fits this request best "
            f"(confidence {picked[1]:.2f}). Weigh it; you decide.")
