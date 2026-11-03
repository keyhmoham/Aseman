"""DeepSeek Harness's ``--json`` run stream.

``dsh --profile headless --json`` writes one JSON object a line:

* ``{"type":"session","sessionId","cwd"}`` first;
* ``{"type":"status","phase":"turn_start"|"step_start"|"step_end"|"turn_end", …}``
  (``turn_end`` carries ``reason: {kind: completed|error|cancelled|max-tokens|…}``,
  ``step_end`` may carry the step's ``usage``);
* ``{"type":"thinking"|"text","text"}`` committed assistant content;
* ``{"type":"tool_call","callId","tool","input"}`` and
  ``{"type":"tool_result","callId","status":"completed"|"error","result"}``;
* ``{"type":"final","sessionId","reason","text"}`` last: the run's answer.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


@dataclass
class ToolStep:
    call_id: str
    tool: str
    input: Any = None
    result: str = ""
    status: str = "pending"


@dataclass
class Parsed:
    reply: str = ""
    session: str = ""
    error: str = ""
    reason: str = ""
    tools: list[ToolStep] = field(default_factory=list)
    todos: list[dict[str, Any]] = field(default_factory=list)
    tokens_in: int = 0
    tokens_out: int = 0

    def asked(self) -> bool:
        return any(_bare(step.tool) == "ask_user" for step in self.tools)


def parse_stream(raw: str) -> Parsed:
    out = Parsed()
    texts: list[str] = []
    final_seen = False
    calls: dict[str, ToolStep] = {}
    for event in _events(raw):
        typ = str(event.get("type") or "")
        if typ == "session":
            out.session = out.session or str(event.get("sessionId") or "")
        elif typ == "text":
            text = event.get("text")
            if isinstance(text, str) and text.strip():
                texts.append(text)
        elif typ == "tool_call":
            step = ToolStep(call_id=str(event.get("callId") or ""), tool=str(event.get("tool") or ""),
                            input=event.get("input"))
            calls[step.call_id] = step
            out.tools.append(step)
            if _bare(step.tool) == "todo_write" and isinstance(step.input, dict):
                todos = step.input.get("todos")
                if isinstance(todos, list):
                    out.todos = [t for t in todos if isinstance(t, dict)]
        elif typ == "tool_result":
            step = calls.get(str(event.get("callId") or ""))
            if step is not None:
                step.status = str(event.get("status") or "completed")
                step.result = str(event.get("result") or "")
        elif typ == "status":
            if event.get("phase") == "turn_end":
                out.reason = _reason(event.get("reason"))
                if out.reason == "error":
                    out.error = _error(event.get("reason")) or out.error or "the dsh turn failed"
            usage = event.get("usage")
            if isinstance(usage, dict):
                out.tokens_in += _int(usage, "input", "inputTokens", "prompt_tokens", "input_tokens")
                out.tokens_out += _int(usage, "output", "outputTokens", "completion_tokens", "output_tokens")
        elif typ == "final":
            final_seen = True
            out.session = str(event.get("sessionId") or out.session)
            text = event.get("text")
            if isinstance(text, str) and text.strip():
                out.reply = text.strip()
            reason = _reason(event.get("reason"))
            if reason:
                out.reason = reason
                if reason == "error":
                    out.error = _error(event.get("reason")) or out.error or "the dsh turn failed"
        elif typ == "error" or "error" in typ:
            message = _stringify(event.get("error") or event.get("message") or "")
            if message:
                out.error = message
    if not out.reply and not final_seen:
        out.reply = (texts[-1] if texts else "").strip()
    return out


def _bare(tool: str) -> str:
    """``mcp__aseman__ask_user`` → ``ask_user``."""
    return tool.rsplit("__", 1)[-1]


def _reason(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("kind") or "")
    if isinstance(value, str):
        return value
    return ""


def _error(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    return _stringify(value.get("error") or value.get("message") or "")


def _int(data: dict, *keys: str) -> int:
    for key in keys:
        value = data.get(key)
        if isinstance(value, (int, float)):
            return int(value)
    return 0


def _events(raw: str) -> list[dict]:
    out = []
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line or line[0] != "{":
            continue
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if isinstance(data, dict):
            out.append(data)
    return out


def _stringify(value: object) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for key in ("message", "error", "cause", "detail"):
            nested = _stringify(value.get(key) or "")
            if nested:
                return nested
        for key in ("code", "kind", "name", "type"):
            label = value.get(key)
            if isinstance(label, str) and label.strip():
                return label.strip()
    return ""
