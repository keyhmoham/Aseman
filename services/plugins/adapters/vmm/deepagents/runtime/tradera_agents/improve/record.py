"""A finished turn as something an agent can learn from: its decision points.

A decision point is a moment of the turn where the agent chose its next step,
with what came of it:

* ``failure`` — a tool call that failed (an error, a non-zero exit);
* ``repeat`` — the same call, with the same arguments, a third time, or
  instructions the agent had already read, read again;
* ``incomplete`` — a final answer that did not deliver what was asked (the
  decision model's completion check, during the turn or after it);
* ``good`` — a step of a turn that went well, kept so that a new playbook is
  also checked against what already works.

Each point keeps the conversation up to that moment (condensed), the step the
agent took and the feedback on it, plus the schemas of the tools the agent had,
so the moment can be replayed (replay.py) without running anything.
"""

from __future__ import annotations

import re
import time
from collections import Counter
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage, convert_to_openai_messages

from ..economy import reference
from ..guard import NOTE, signature

#: How much of each message a decision point keeps (characters).
HUMAN_CHARS = 3_000
TEXT_CHARS = 1_500
RESULT_CHARS = 1_500
ARG_CHARS = 600
#: The conversation a point keeps before it: the request, then the latest messages.
HISTORY = 16
#: Points one turn gives, at most (the problems first).
MAX_POINTS = 6
#: A turn this good (and without problems) gives examples of what works.
GOOD_ABOVE = 0.75
#: A final answer the decision model gives less than this did not deliver.
INCOMPLETE_BELOW = 0.25

_EXIT = re.compile(r"\bexit(?:ed with)?(?: code|_code)?[:= ]+([1-9]\d*)\b", re.I)


def failed(result: ToolMessage | None) -> bool:
    if result is None:
        return False
    text = result.text.strip()
    return getattr(result, "status", "") == "error" or text.lower().startswith(("error", "traceback")) or \
        bool(_EXIT.search(text[:300]))


def _clip(value: Any, n: int) -> Any:
    if isinstance(value, str):
        return value if len(value) <= n else value[:n] + f"… [{len(value) - n} more characters]"
    if isinstance(value, dict):
        return {k: _clip(v, n) for k, v in value.items()}
    if isinstance(value, list):
        return [_clip(v, n) for v in value]
    return value


def condensed(messages: list[BaseMessage]) -> list[dict[str, Any]]:
    """Messages as OpenAI-style dicts, each clipped, pictures left out.

    A tool result is never emitted without the call it answers: a turn resumed
    from a human-in-the-loop interrupt opens with the interrupt's result, whose
    call is in the checkpoint before it, and a provider rejects the replay with
    "the referenced tool call was not found" if that lone result is sent.
    """
    out = []
    calls = {c.get("id") for m in messages if isinstance(m, AIMessage) for c in m.tool_calls or []}
    for m in messages:
        if isinstance(m, HumanMessage):
            m = HumanMessage(content=_clip(m.text, HUMAN_CHARS))
        elif isinstance(m, ToolMessage):
            if m.tool_call_id not in calls:
                continue
            m = m.model_copy(update={"content": _clip(m.text, RESULT_CHARS)})
        elif isinstance(m, AIMessage):
            m = m.model_copy(update={"content": _clip(m.text, TEXT_CHARS),
                                     "tool_calls": [dict(c, args=_clip(c.get("args") or {}, ARG_CHARS))
                                                    for c in m.tool_calls or []]})
        out.extend(convert_to_openai_messages([m]))
    return out


def _history(messages: list[BaseMessage], at: int) -> list[dict[str, Any]]:
    """The conversation before message ``at``: the request and the latest messages."""
    before = messages[:at]
    if len(before) > HISTORY + 1:
        before = before[:1] + before[-HISTORY:]
        # A tool result is never shown without the call it answers.
        while len(before) > 1 and isinstance(before[1], ToolMessage):
            before.pop(1)
    return condensed(before)


def points(messages: list[BaseMessage], quality: float, complete: float | None) -> list[dict[str, Any]]:
    """The turn's decision points (see the module docstring)."""
    results = {m.tool_call_id: m for m in messages if isinstance(m, ToolMessage)}
    seen: Counter[str] = Counter()
    problems: list[dict[str, Any]] = []
    good: list[dict[str, Any]] = []
    for i, m in enumerate(messages):
        text = m.text if isinstance(m, HumanMessage) else ""
        if text.startswith(NOTE) and "independent check" in text:
            # The decision model's completion check sent the agent back: its answer before fell short.
            j = max((k for k in range(i) if isinstance(messages[k], AIMessage) and not messages[k].tool_calls), default=-1)
            if j >= 0:
                problems.append({"kind": "incomplete", "at": j, "action": {"text": messages[j].text[:TEXT_CHARS]},
                                 "feedback": "An independent check found this answer did not deliver the request: "
                                             "it promised work that was not done, or left part of the request out."})
            continue
        if not isinstance(m, AIMessage):
            continue
        for call in m.tool_calls or []:
            action = {"name": call.get("name", ""), "args": _clip(call.get("args") or {}, ARG_CHARS)}
            result = results.get(call.get("id", ""))
            outcome = result.text[:600] if result is not None else ""
            seen[signature(call)] += 1
            # Instructions read once stay in context: the same read a second time is a repeat already.
            if reference(call) and seen[signature(call)] == 2:
                problems.append({"kind": "repeat", "at": i, "action": action,
                                 "feedback": f"`{action['name']}` had already been read in this turn, and what it "
                                             f"returned was still in the agent's context; reading these instructions "
                                             f"again added nothing."})
            elif seen[signature(call)] == 3 and not reference(call):
                problems.append({"kind": "repeat", "at": i, "action": action,
                                 "feedback": f"This exact call (`{action['name']}` with the same arguments) had already "
                                             f"been made twice, with the same result; repeating it changed nothing. "
                                             f"Its result: {outcome[:300]}"})
            elif failed(result):
                problems.append({"kind": "failure", "at": i, "action": action,
                                 "feedback": f"`{action['name']}` failed: {outcome}"})
            elif result is not None and len(good) < 2:
                good.append({"kind": "good", "at": i, "action": action,
                             "feedback": f"This step worked: {outcome[:300]}"})
    last = max((k for k, m in enumerate(messages) if isinstance(m, AIMessage) and not m.tool_calls), default=-1)
    if complete is not None and complete < INCOMPLETE_BELOW and last >= 0 and \
            not any(p["kind"] == "incomplete" and p["at"] == last for p in problems):
        problems.append({"kind": "incomplete", "at": last, "action": {"text": messages[last].text[:TEXT_CHARS]},
                         "feedback": f"An independent check rates the chance that this answer delivers the request at "
                                     f"{complete:.2f}: it promised work that was not done, or left part of it out."})
    chosen = problems[:MAX_POINTS]
    if not problems and quality >= GOOD_ABOVE:
        chosen = good
    for p in chosen:
        p["history"] = _history(messages, p["at"])
    return chosen


def turn(request: str, outcome: Any, messages: list[BaseMessage], *, quality: float, complete: float | None,
         steps: int, budget: int, version: int, tools: list[str]) -> dict[str, Any]:
    """A finished turn, as the agent's store keeps it (``tools``: the ones the agent had)."""
    return {"at": time.time(), "request": request[:HUMAN_CHARS], "answer": (outcome.reply or "")[:TEXT_CHARS],
            "status": outcome.status, "quality": round(quality, 4), "steps": steps, "budget": budget,
            "playbook": version, "tools": sorted(tools),
            "points": points(messages, quality, complete)}


def quality(outcome: Any, complete: float | None, messages: list[BaseMessage], steps: int, budget: int) -> float:
    """How a turn went, without knowing the right answer: whether it delivered
    (the decision model's judgement, else whether it answered at all), how many
    of its steps it needed, and how many of its tool calls failed."""
    if outcome.status == "failed":
        return 0.0
    if outcome.status == "awaiting":
        return 0.6
    delivered = complete if complete is not None else (1.0 if (outcome.reply or "").strip() else 0.0)
    results = [m for m in messages if isinstance(m, ToolMessage)]
    errors = sum(1 for r in results if failed(r)) / len(results) if results else 0.0
    efficiency = 1.0 - min(1.0, steps / max(1, budget))
    return max(0.0, min(1.0, 0.75 * delivered + 0.25 * efficiency - 0.2 * errors))
