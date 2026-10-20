"""Keeping a turn from running away.

A turn is bounded by the number of model calls it makes, not by LangGraph's
recursion limit: every model call is several graph steps (the model, the
tools and each middleware hook), so a step limit is a poor proxy and ends the
turn with an error and no answer. Instead:

* the agent is told when it repeats the same tool call, or keeps polling for
  tasks, that the result will not change and it should change approach;
* it is told, too, when it fetches again what it already has: the same call
  earlier in the turn, or instructions it already read (they stay whole in its
  context, see ``reference``);
* what it is told is enforced where the tools run: a call that would only
  repeat itself is not run (the same call twice in one step, instructions read
  again, a call that already returned the same result twice) and the agent
  gets why instead; one that keeps doing so has its tools taken away;
* a few calls before its budget it is told to wrap up;
* its last call has no tools: it writes its final answer, so the turn ends
  with the result and what is left rather than an error.

The graph's recursion limit is then set well above what the budget needs (see
``recursion_limit``), as a backstop only.
"""

from __future__ import annotations

import json
import os
import re
from collections import Counter
from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

#: Model calls a turn may make when the agent sets no max_turns.
DEFAULT_MAX_CALLS = 150
#: The same tool call (name and arguments) this many times in a row of recent calls is a loop.
REPEATS = 3
#: How many of the most recent tool calls are checked for repeats.
WINDOW = 12
#: Polling tools: this many calls in a turn is enough.
POLL_TOOLS = frozenset({"check_tasks", "read_room", "read_direct_messages"})
POLLS = 6
#: Calls before the budget at which the agent is told to wrap up.
WARN_BEFORE = 5
#: The same read of instructions this many times in a turn is re-reading.
REFERENCE_READS = 2
#: Calls not run for repeating themselves before the agent's tools are taken away.
BLOCKS = 4
#: Tools whose result changes with time, whatever their arguments: never refused for repeating.
LIVE_TOOLS = POLL_TOOLS | {"wait_tasks"}

#: Tools that return instructions, documentation or rules (an app's "get instructions"
#: or "help"): what the agent reads to know how to work, not results of the work.
REFERENCE_TOOLS = re.compile(
    r"(?:^|_)(?:instructions?|help|guides?|docs?|documentation|usage|manual|readme|reference|howto|how_to|"
    r"rules|tutorial|get_started|getting_started|best_practices|skills?|specs?|specification|guidelines?|"
    r"conventions?)(?:_|$)", re.I)
#: ...unless the tool changes something (``create_doc``, ``set_rules``).
WRITE_TOOLS = re.compile(r"(?:^|_)(?:create|update|delete|remove|set|add|write|edit|post|send|upload|publish|"
                         r"move|rename|insert|replace)(?:_|$)", re.I)
#: Files that hold instructions: skills and agents' notes.
REFERENCE_FILES = re.compile(r"(?:^|/)(?:SKILL|AGENTS|README)\.md$|/skills/.+\.md$", re.I)

NOTE = "[runtime note] "


def max_calls(max_turns: int) -> int:
    if max_turns > 0:
        return max_turns
    try:
        return max(5, int(os.environ.get("TRADERA_MAX_MODEL_CALLS", "") or DEFAULT_MAX_CALLS))
    except ValueError:
        return DEFAULT_MAX_CALLS


def recursion_limit(graph: Any, calls: int) -> int:
    """A recursion limit the call budget never reaches: graph steps per model
    call (every node a model call goes through) times the budget, with room."""
    try:
        nodes = [n for n in graph.get_graph().nodes
                 if n not in ("__start__", "__end__") and not n.endswith((".before_agent", ".after_agent"))]
        per_call = max(2, len(nodes))
    except Exception:  # noqa: BLE001 - a conservative guess
        per_call = 10
    return (calls + 5) * per_call + 50


def reference(call: dict[str, Any]) -> bool:
    """Whether a tool call reads instructions rather than doing work."""
    name = call.get("name", "")
    if name == "read_file":
        return bool(REFERENCE_FILES.search(str((call.get("args") or {}).get("file_path", ""))))
    return bool(REFERENCE_TOOLS.search(name)) and not WRITE_TOOLS.search(name)


def _signature(call: dict[str, Any]) -> str:
    return call.get("name", "") + json.dumps(call.get("args") or {}, sort_keys=True, default=str)


def _run_calls(messages: list[Any]) -> list[dict[str, Any]]:
    """The tool calls the agent made since the last message from a person."""
    calls: list[dict[str, Any]] = []
    for m in reversed(messages):
        # The runtime's own notes in the history are not a new request.
        if isinstance(m, HumanMessage) and not str(m.content).startswith(NOTE):
            break
        if isinstance(m, AIMessage) and m.tool_calls:
            calls[:0] = m.tool_calls
    return calls


def notes(messages: list[Any], calls_made: int, budget: int) -> list[str]:
    """What the agent should be told before its next step."""
    out: list[str] = []
    calls = _run_calls(messages)
    recent = Counter(_signature(c) for c in calls[-WINDOW:])
    repeated = sorted({c.get("name", "") for c in calls[-WINDOW:] if recent[_signature(c)] >= REPEATS})
    if repeated:
        out.append(f"You called {', '.join(repeated)} with the same arguments {REPEATS} or more times recently. "
                   "Its result will not change: use what you already have, try a different approach, or finish "
                   "with what you have and say what is left.")
    # The same call again much later: what it returned dropped out of view and is fetched again.
    whole = Counter(_signature(c) for c in calls)
    refetched = sorted({c.get("name", "") for c in calls if whole[_signature(c)] >= REPEATS} - set(repeated))
    if refetched:
        out.append(f"You have made the same {', '.join(refetched)} call {REPEATS} or more times this turn. If you "
                   "are fetching again something you already read, stop: write down what you need from it (in "
                   "your plan with write_todos, or a file) and go on with the work.")
    reread = sorted({c.get("name", "") for c in calls
                     if reference(c) and whole[_signature(c)] >= REFERENCE_READS} - set(repeated) - set(refetched))
    if reread:
        out.append(f"You have already read these instructions this turn: {', '.join(reread)}. They stay in full "
                   "in your context: use them as they are instead of reading them again.")
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
        # Model calls the agent was told it was looping before (repeats, polling,
        # re-reading): the agent's learning takes such a turn up sooner.
        self.loops = 0
        # What each call (name and arguments) returned this turn, the id of its
        # latest run, and the calls running now.
        self.results: dict[str, list[str]] = {}
        self.last_run: dict[str, str] = {}
        self.running: set[str] = set()
        # Calls not run because they only repeated themselves.
        self.blocked = 0

    @property
    def exhausted(self) -> bool:
        return self.calls >= self.budget

    @property
    def final(self) -> bool:
        """Whether the next model call may run no tools."""
        return self.exhausted or self.blocked >= BLOCKS

    def _request(self, request: Any) -> Any:
        self.calls += 1
        if self.final:
            note = ("This turn has used all its steps: no more tools can run. " if self.exhausted else
                    "You kept repeating calls that could only return what you already have, so no more tools "
                    "can run in this turn. ")
            note += "Write your final answer now: what you did, the results and where they are, and what is left to do."
            return request.override(messages=[*request.messages, HumanMessage(NOTE + note)], tool_choice="none")
        found = notes(request.messages, self.calls, self.budget)
        if not found:
            return request
        if any("steps left" not in n for n in found):
            self.loops += 1
        return request.override(messages=[*request.messages, HumanMessage(NOTE + "\n".join(found))])

    def _response(self, response: Any) -> Any:
        if not self.final:
            return response
        # The last call may not run tools, whatever the model answered.
        result = getattr(response, "result", None)
        if isinstance(result, list):
            for i, m in enumerate(result):
                if isinstance(m, AIMessage) and m.tool_calls:
                    text = m.text if isinstance(m.text, str) else ""
                    result[i] = m.model_copy(update={
                        "tool_calls": [], "invalid_tool_calls": [],
                        "content": text.strip() or "I ran out of steps for this turn before finishing. "
                                                   "Ask me to continue and I will pick up where I left off.",
                    })
        return response

    def _kept(self, sig: str, state: Any) -> str:
        """Where the latest result of a call still is, whole: "context", a file's
        path, or nothing when it was trimmed or summarized away."""
        messages = state.get("messages") if isinstance(state, dict) else getattr(state, "messages", None)
        cid = self.last_run.get(sig)
        found = next((m for m in reversed(messages or []) if isinstance(m, ToolMessage) and m.tool_call_id == cid),
                     None) if cid else None
        if found is None or (found.response_metadata or {}).get("trimmed"):
            return ""
        text = found.content if isinstance(found.content, str) else str(found.content)
        if text.startswith("Tool result too large"):
            path = re.search(r"at this path: (\S+)", text)
            return path.group(1) if path else ""
        return "context"

    def _refusal(self, call: dict[str, Any], state: Any = None) -> str:
        """Why a tool call is not run, or nothing when it runs."""
        sig = _signature(call)
        if sig in self.running:
            return ("Not run: the same call (same tool and arguments) is already running in this step. "
                    "Use its result.")
        if call.get("name") in LIVE_TOOLS:
            return ""
        done = self.results.get(sig, [])
        kept = self._kept(sig, state) if done and reference(call) else ""
        if kept == "context":
            return ("Not run: you already read these instructions in this turn with the same arguments, and they "
                    "have not changed. They are earlier in this conversation, in full (the result of call "
                    f"{self.last_run[sig]}). Follow them now: do the next step of the work.")
        if kept:
            return ("Not run: you already read these instructions in this turn with the same arguments, and they "
                    f"have not changed. They are in the file {kept}: read the part you need with read_file "
                    "(offset and limit) instead of asking for them again.")
        if len(done) >= REPEATS - 1 and len(set(done[-(REPEATS - 1):])) == 1:
            return (f"Not run: this exact call already returned the same result {len(done)} times in this turn, "
                    "and it will not change. Use that result (it is earlier in this conversation), try a "
                    "different approach, or finish and say what is left.")
        return ""

    def _before_tool(self, request: Any) -> ToolMessage | None:
        call = request.tool_call
        refusal = self._refusal(call, getattr(request, "state", None))
        if not refusal:
            self.running.add(_signature(call))
            return None
        self.blocked += 1
        self.loops += 1
        return ToolMessage(content=NOTE + refusal, name=call.get("name", ""), tool_call_id=call.get("id", ""),
                           status="error")

    def _after_tool(self, request: Any, result: Any) -> Any:
        sig = _signature(request.tool_call)
        if isinstance(result, ToolMessage) and getattr(result, "status", "") != "error":
            content = result.content
            text = content if isinstance(content, str) else json.dumps(content, sort_keys=True, default=str)
            if not text.startswith(("error:", "The app reported an error")):
                self.results.setdefault(sig, []).append(text)
                self.last_run[sig] = result.tool_call_id
        return result

    def wrap_tool_call(self, request: Any, handler: Any) -> Any:
        refused = self._before_tool(request)
        if refused is not None:
            return refused
        try:
            return self._after_tool(request, handler(request))
        finally:
            self.running.discard(_signature(request.tool_call))

    async def awrap_tool_call(self, request: Any, handler: Any) -> Any:
        refused = self._before_tool(request)
        if refused is not None:
            return refused
        try:
            return self._after_tool(request, await handler(request))
        finally:
            self.running.discard(_signature(request.tool_call))

    def wrap_model_call(self, request: Any, handler: Any) -> Any:
        return self._response(handler(self._request(request)))

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        return self._response(await handler(self._request(request)))
