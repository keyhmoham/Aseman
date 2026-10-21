"""Tool selection: the tools a request needs, chosen once per turn.

Every model call carries the schema of every tool the agent has, and each
command of every connected app is a tool of its own: a lead with four apps
sends some 80 tool schemas (~10k tokens) on every step. The decision model is
asked once per turn, one yes/no question per tool in a single request, which
tools the request needs; the agent's model then sees those.

Kept safe and cheap:

* a connected app is chosen whole: its functions work together (one reads
  how to use the app or lists what is there, the next acts on it), so the
  decision is made per app, never per function. Chosen function by function,
  an app's "get instructions" was kept and the function those instructions
  say to call was hidden: the agent, with no such tool in its list, read the
  instructions again or called other tools, over and over;
* the agent's own working tools (the sandbox, files, planning, messaging,
  delegation, the project's timeline) are never hidden — only app, bot and platform tools are chosen;
* the choice is made once and only grows during the turn (a tool the agent
  uses stays), so the tool list — part of the provider's cached prompt
  prefix — stays the same from one call to the next;
* the agent is told the names of the tools not shown and can call any of
  them: every tool still runs when called. A hidden tool that the
  conversation names (an app's instructions, a result, the agent itself) is
  shown from the next call on, with the rest of its app: a model rarely
  calls a tool whose schema it was not given;
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
    "write_todos", "task", "recruit_agent", "assemble_team", "run_swarm", "read_attachment",
} | TIMELINE_TOOLS)
#: Choose only when at least this many tools are choosable.
MIN_CANDIDATES = 8
#: More choosable tools than one decision request takes: show them all.
MAX_CANDIDATES = 250
#: A tool is shown when the decision model gives it at least this probability.
KEEP_ABOVE = 0.35
#: At most this many chosen apps and tools are shown (an app with all its functions).
MAX_SHOWN = 24
#: The request text the decision is made on (its end: the message itself).
REQUEST_CHARS = 4000


def tool_name(tool: Any) -> str:
    if isinstance(tool, dict):
        return str(tool.get("name") or (tool.get("function") or {}).get("name") or "")
    return str(getattr(tool, "name", "") or "")


def app_of(name: str) -> str:
    """The connected app a tool is a function of (``board__create_items`` is
    one of ``board``'s), or "" for a tool of its own."""
    app, sep, function = name.partition("__")
    return app if sep and app and function else ""


def tool_description(tool: Any) -> str:
    if isinstance(tool, dict):
        text = tool.get("description") or (tool.get("function") or {}).get("description") or ""
    else:
        text = getattr(tool, "description", "") or ""
    return " ".join(str(text).split())[:300]


def _groups(tools: list[Any]) -> list[tuple[str, list[Any]]]:
    """The choosable tools, an app's functions together: (app or tool name, tools)."""
    groups: dict[str, list[Any]] = {}
    for t in tools:
        name = tool_name(t)
        groups.setdefault(app_of(name) or name, []).append(t)
    return list(groups.items())


def _question(key: str, members: list[Any]) -> str:
    if len(members) == 1 and tool_name(members[0]) == key:
        return f"Will the agent need the tool `{key}` ({tool_description(members[0])}) to handle `request`?"
    functions = ", ".join(tool_name(t).partition("__")[2] for t in members)
    if len(functions) > 600:
        functions = functions[:600].rsplit(",", 1)[0] + ", …"
    return (f"Will the agent need the app `{key}` ({tool_description(members[0])[:150]}; its functions: "
            f"{functions}) to handle `request`?")


async def shortlist(client: DecisionClient, request: str, tools: list[Any]) -> set[str] | None:
    """The names of the choosable tools the request needs, or None to show
    every tool (too few to choose from, or no decision could be made)."""
    candidates = [t for t in tools if tool_name(t) and tool_name(t) not in PINNED]
    if not MIN_CANDIDATES <= len(candidates) <= MAX_CANDIDATES or not request.strip():
        return None
    groups = _groups(candidates)
    questions = {
        f"t{i}": {"type": "boolean",
                  "instructions": _question(key, members),
                  "criteria": {"true": "it does part of what the request asks for",
                               "false": "it is unrelated to the request"}}
        for i, (key, members) in enumerate(groups)
    }
    answers = await client.evaluate({"request": request[-REQUEST_CHARS:]}, questions)
    if answers is None:
        return None
    scored = []
    for i, (_, members) in enumerate(groups):
        p = probability(answers, f"t{i}")
        scored.append((1.0 if p is None else p, i))  # unanswered: keep it
    scored.sort(key=lambda s: -s[0])
    return {tool_name(t) for p, i in scored[:MAX_SHOWN] if p >= KEEP_ABOVE for t in groups[i][1]}


def unlocked(hidden: list[str], named: str | set[str]) -> set[str]:
    """The hidden tools to show: those named (a set of tool names, or text that
    mentions them), each with the rest of its app."""
    if isinstance(named, str):
        named = {n for n in hidden if n in named}
    apps = {app_of(n) for n in named if app_of(n)}
    return {n for n in hidden if n in named or app_of(n) in apps}


def hidden_note(hidden: list[str]) -> str:
    names = ", ".join(sorted(hidden))
    if len(names) > 2000:
        names = names[:2000].rsplit(",", 1)[0] + ", …"
    return (f"Not shown to save space, but available — call any by name if the work needs it: {names}.")
