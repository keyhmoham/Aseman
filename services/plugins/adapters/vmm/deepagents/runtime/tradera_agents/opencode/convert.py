"""What the relay changes between OpenCode and the model.

OpenCode names an MCP server's tools ``<server>_<tool>``; the agent's tools
are the runtime's MCP server ``tradera``, so OpenCode knows ``execute`` as
``tradera_execute``. The model sees every tool under its own name, as the
prompts, the turn guard and the decision model know them, and OpenCode gets
its names back in the model's answers. OpenCode's own ``task`` tool (the
agent's harness subagents) is ``subagent`` to the model, since ``task`` is the
delegation to the space's agents.

The turn guard and the decision model read a conversation as LangChain
messages: the relay converts OpenAI-style messages to them.
"""

from __future__ import annotations

import json
import re
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage

#: The runtime's MCP server, as OpenCode's config names it.
MCP_SERVER = "tradera"
PREFIX = MCP_SERVER + "_"
#: OpenCode's own tools the model may see, under the names it sees them.
BUILTINS = {"task": "subagent", "skill": "skill"}
_TO_OPENCODE = {v: k for k, v in BUILTINS.items()}

# OpenCode's description of its own environment (its working directory is not
# where agents work: they work in the space's sandbox).
_ENV_BLOCK = re.compile(r"\n?You are powered by the model named.*?</env>\n?", re.S)


def to_model(name: str) -> str:
    if name.startswith(PREFIX):
        return name[len(PREFIX):]
    return BUILTINS.get(name, name)


def to_opencode(name: str) -> str:
    if name in _TO_OPENCODE:
        return _TO_OPENCODE[name]
    return name if name.startswith(PREFIX) else PREFIX + name


def strip_env(text: str) -> str:
    return _ENV_BLOCK.sub("\n", text).strip()


def model_request(body: dict[str, Any]) -> dict[str, Any]:
    """A chat completions request from OpenCode with the model's tool names."""
    for t in body.get("tools") or []:
        fn = t.get("function") if isinstance(t, dict) else None
        if isinstance(fn, dict) and fn.get("name"):
            fn["name"] = to_model(fn["name"])
    for m in body.get("messages") or []:
        for call in m.get("tool_calls") or []:
            fn = call.get("function") or {}
            if fn.get("name"):
                fn["name"] = to_model(fn["name"])
        if m.get("role") == "tool" and m.get("name"):
            m["name"] = to_model(m["name"])
    choice = body.get("tool_choice")
    if isinstance(choice, dict) and isinstance(choice.get("function"), dict) and choice["function"].get("name"):
        choice["function"]["name"] = to_model(choice["function"]["name"])
    return body


def opencode_message(message: dict[str, Any]) -> dict[str, Any]:
    """A model message (or a streamed delta) with OpenCode's tool names."""
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        if fn.get("name"):
            fn["name"] = to_opencode(fn["name"])
    return message


def text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") in ("text", None))
    return "" if content is None else str(content)


def _args(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    try:
        out = json.loads(raw or "{}")
    except ValueError:
        return {"_raw": raw}
    return out if isinstance(out, dict) else {"_value": out}


def to_langchain(messages: list[dict[str, Any]]) -> list[BaseMessage]:
    """OpenAI-style messages as LangChain messages (names, calls and results kept)."""
    out: list[BaseMessage] = []
    names: dict[str, str] = {}
    for m in messages:
        role = m.get("role")
        content = m.get("content")
        if role == "system":
            out.append(SystemMessage(content=text_of(content)))
        elif role == "user":
            out.append(HumanMessage(content=content if isinstance(content, (str, list)) else text_of(content)))
        elif role == "assistant":
            calls = []
            for c in m.get("tool_calls") or []:
                fn = c.get("function") or {}
                calls.append({"name": fn.get("name", ""), "args": _args(fn.get("arguments")), "id": c.get("id", ""),
                              "type": "tool_call"})
                names[c.get("id", "")] = fn.get("name", "")
            out.append(AIMessage(content=text_of(content), tool_calls=calls))
        elif role == "tool":
            cid = m.get("tool_call_id", "")
            out.append(ToolMessage(content=text_of(content), tool_call_id=cid, name=m.get("name") or names.get(cid, "")))
    return out


def note_message(text: str) -> dict[str, Any]:
    return {"role": "user", "content": text}
