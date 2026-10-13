"""Tool selection: the tools a request needs, chosen once per turn.

Every model call carries the schema of every tool the agent has, and each
command of every connected app is a tool of its own: a lead with four apps
sends some 80 tool schemas (~10k tokens) on every step. The decision model is
asked once per turn, one yes/no question per tool in a single request, which
tools the request needs; the agent's model then sees those.

Kept safe and cheap:

* the agent's own working tools (the sandbox, files, planning, messaging,
  delegation, the project's timeline) are never hidden — only app, bot and platform tools are chosen;
* the choice is made once and only grows during the turn (a tool the agent
  uses stays), so the tool list — part of the provider's cached prompt
  prefix — stays the same from one call to the next;
* the agent is told the names of the tools not shown and can call any of
  them: every tool still runs when called;
* below a handful of choosable tools nothing is chosen.
"""

from __future__ import annotations

from typing import Any

from ..timeline import AGENT_TOOLS as TIMELINE_TOOLS
from ..tools import CORE_TOOLS
from .client import DecisionClient, probability

#: Never hidden: how the agent works, plans, talks and delegates.
PINNED = frozenset(CORE_TOOLS | {
    "ls", "read_file", "write_file", "edit_file", "glob", "grep", "execute",
    "write_todos", "task", "recruit_agent", "read_attachment",
} | TIMELINE_TOOLS)
#: Choose only when at least this many tools are choosable.
MIN_CANDIDATES = 8
#: More choosable tools than one decision request takes: show them all.
MAX_CANDIDATES = 250
#: A tool is shown when the decision model gives it at least this probability.
KEEP_ABOVE = 0.35
#: At most this many chosen tools are shown.
MAX_SHOWN = 24
#: The request text the decision is made on (its end: the message itself).
REQUEST_CHARS = 4000


def tool_name(tool: Any) -> str:
    if isinstance(tool, dict):
        return str(tool.get("name") or (tool.get("function") or {}).get("name") or "")
    return str(getattr(tool, "name", "") or "")


def tool_description(tool: Any) -> str:
    if isinstance(tool, dict):
        text = tool.get("description") or (tool.get("function") or {}).get("description") or ""
    else:
        text = getattr(tool, "description", "") or ""
    return " ".join(str(text).split())[:300]


async def shortlist(client: DecisionClient, request: str, tools: list[Any]) -> set[str] | None:
    """The names of the choosable tools the request needs, or None to show
    every tool (too few to choose from, or no decision could be made)."""
    candidates = [t for t in tools if tool_name(t) and tool_name(t) not in PINNED]
    if not MIN_CANDIDATES <= len(candidates) <= MAX_CANDIDATES or not request.strip():
        return None
    questions = {
        f"t{i}": {"type": "boolean",
                  "instructions": f"Will the agent need the tool `{tool_name(t)}` ({tool_description(t)}) "
                                  "to handle `request`?",
                  "criteria": {"true": "the tool does part of what the request asks for",
                               "false": "the tool is unrelated to the request"}}
        for i, t in enumerate(candidates)
    }
    answers = await client.evaluate({"request": request[-REQUEST_CHARS:]}, questions)
    if answers is None:
        return None
    scored = []
    for i, t in enumerate(candidates):
        p = probability(answers, f"t{i}")
        scored.append((1.0 if p is None else p, tool_name(t)))  # unanswered: keep it
    scored.sort(key=lambda s: -s[0])
    return {name for p, name in scored[:MAX_SHOWN] if p >= KEEP_ABOVE}


def hidden_note(hidden: list[str]) -> str:
    names = ", ".join(sorted(hidden))
    if len(names) > 2000:
        names = names[:2000].rsplit(",", 1)[0] + ", …"
    return (f"Not shown to save space, but available — call any by name if the work needs it: {names}.")
