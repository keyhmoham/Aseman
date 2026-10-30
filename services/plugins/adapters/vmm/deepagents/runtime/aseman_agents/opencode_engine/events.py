"""OpenCode's ``--format json`` stream, read loosely.

Events differ a little by version. The fields we need are the session id,
assistant text, a fatal error, and an ``ask_user`` tool call.
"""

from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass
class Parsed:
    reply: str = ""
    session: str = ""
    error: str = ""
    ask: str = ""
    options: list[str] | None = None


def parse_stream(raw: str) -> Parsed:
    texts: list[str] = []
    deltas: list[str] = []
    session = ""
    error = ""
    ask = ""
    options: list[str] = []
    for event in _events(raw):
        session = session or _session(event)
        typ = str(event.get("type") or "")
        if "error" in typ:
            message = _stringify(event.get("error") or event.get("message") or "")
            if message:
                error = message
        tool_name = _tool(event)
        if tool_name in ("ask_user", "aseman_engine_ask_user", "aseman-engine_ask_user") or tool_name.endswith("_ask_user"):
            question, opts = _ask(event)
            if question:
                ask = question
            options = opts or options
        text = _text(event)
        if not text:
            continue
        if "delta" in typ:
            deltas.append(text)
        else:
            texts.append(text)
    reply = "\n".join(part for part in texts if part.strip()).strip() or "".join(deltas).strip()
    return Parsed(reply=reply, session=session, error=error, ask=ask, options=options or None)


def _events(raw: str) -> list[dict]:
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line[0] not in "{[":
            continue
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if isinstance(data, dict):
            out.append(data)
        elif isinstance(data, list):
            out.extend(item for item in data if isinstance(item, dict))
    return out


def _session(event: dict) -> str:
    for key in ("sessionID", "sessionId", "session_id"):
        if event.get(key):
            return str(event[key])
    part = event.get("part")
    if isinstance(part, dict):
        for key in ("sessionID", "sessionId", "session_id"):
            if part.get(key):
                return str(part[key])
    info = event.get("session")
    if isinstance(info, dict) and info.get("id"):
        return str(info["id"])
    if isinstance(info, str):
        return info
    return ""


def _text(event: dict) -> str:
    part = event.get("part")
    if isinstance(part, dict):
        if part.get("type") in ("text", "reasoning") and isinstance(part.get("text"), str):
            if part.get("type") == "reasoning":
                return ""
            return part["text"]
        if isinstance(part.get("text"), str) and event.get("type") in ("text", "message", None):
            return part["text"]
    for key in ("text", "content", "delta"):
        value = event.get(key)
        if isinstance(value, str) and event.get("type") not in ("tool", "tool_use", "step_start", "step_finish"):
            return value
    return ""


def _tool(event: dict) -> str:
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    for source in (event, part, part.get("state") if isinstance(part.get("state"), dict) else {}):
        for key in ("tool", "name", "tool_name"):
            if source.get(key):
                return str(source[key])
    return ""


def _ask(event: dict) -> tuple[str, list[str]]:
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    state = part.get("state") if isinstance(part.get("state"), dict) else {}
    blob = state.get("input") or event.get("input") or event.get("args") or {}
    if not isinstance(blob, dict):
        return "", []
    question = str(blob.get("question") or "").strip()
    options = [str(item) for item in blob.get("options") or [] if str(item).strip()]
    return question, options[:8]


def _stringify(value: object) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        return str(value.get("message") or value.get("error") or "").strip()
    return ""
