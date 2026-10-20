"""The context diet of the deepagents engine (economy.py), on the relay.

OpenCode keeps a turn's whole conversation and sends it again on every model
call; without a diet every call carries every old command output and
screenshot, which makes each step slower, costlier and worse. Before each of
the agent's own calls the relay applies the deepagents engine's rules to what
is sent (OpenCode's own history is left whole):

* old screenshots and pictures are dropped once the agent has moved on (the
  newest few stay);
* once the conversation is large, old tool output is trimmed to its opening
  lines (the newest results, and the answers that cannot be had again by
  re-running a tool, stay whole), and the long arguments of old tool calls
  (a file written whole) are shortened, as the deepagents engine's
  summarization did.

The rules only depend on the conversation itself, so a message trimmed once is
trimmed the same way on every later call and the provider's prompt cache keeps
matching the prefix.
"""

from __future__ import annotations

import json
from typing import Any

from .. import economy

_MEDIA = frozenset({"image_url", "image", "input_image", "file", "input_audio", "audio", "video"})


def _chars(m: dict[str, Any]) -> int:
    content = m.get("content")
    if isinstance(content, str):
        n = len(content)
    elif isinstance(content, list):
        n = sum(len(p.get("text", "")) if isinstance(p, dict) and p.get("type") == "text" else 1000 for p in content)
    else:
        n = 0
    return n + sum(len(json.dumps(c)) for c in m.get("tool_calls") or [])


def _has_media(m: dict[str, Any]) -> bool:
    content = m.get("content")
    return isinstance(content, list) and any(isinstance(p, dict) and p.get("type") in _MEDIA for p in content)


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def trim(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The messages to send, on the deepagents engine's diet."""
    out = list(messages)
    with_media = [i for i, m in enumerate(out) if _has_media(m)]
    for i in with_media[:-economy.KEEP_MEDIA] if economy.KEEP_MEDIA else with_media:
        m = out[i]
        kept = [p for p in m["content"] if not (isinstance(p, dict) and p.get("type") in _MEDIA)]
        gone = economy._MEDIA_GONE if m.get("role") == "tool" else economy._ATTACHED_GONE
        out[i] = {**m, "content": [*kept, {"type": "text", "text": gone}]}
    if sum(_chars(m) for m in out) / economy.CHARS_PER_TOKEN <= economy.TRIM_ABOVE:
        return out
    names = {c.get("id"): (c.get("function") or {}).get("name", "")
             for m in out for c in m.get("tool_calls") or []}
    calls = [i for i, m in enumerate(out) if m.get("role") == "assistant" and m.get("tool_calls")]
    for i in calls[:-economy.KEEP_RESULTS] if economy.KEEP_RESULTS else calls:
        out[i] = {**out[i], "tool_calls": [_short_call(c) for c in out[i]["tool_calls"]]}
    results = [i for i, m in enumerate(out) if m.get("role") == "tool"]
    for i in results[:-economy.KEEP_RESULTS] if economy.KEEP_RESULTS else results:
        m = out[i]
        if names.get(m.get("tool_call_id")) in economy.NEVER_TRIM:
            continue
        text = _text(m.get("content"))
        if len(text) <= economy.KEEP_CHARS * 2:
            continue
        head = text[:economy.KEEP_CHARS].rstrip()
        out[i] = {**m, "content": f"{head}\n… [{len(text) - len(head)} more characters trimmed from context. You "
                                  "already used this result; run the tool again only if you need its exact text]"}
    return out


#: A string argument of an old tool call longer than this is shortened.
ARG_MAX_CHARS = 1_000


def _shorten(value: Any) -> Any:
    if isinstance(value, str) and len(value) > ARG_MAX_CHARS:
        return value[:ARG_MAX_CHARS] + f"… [{len(value) - ARG_MAX_CHARS} more characters left out of context]"
    if isinstance(value, dict):
        return {k: _shorten(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_shorten(v) for v in value]
    return value


def _short_call(call: dict[str, Any]) -> dict[str, Any]:
    """An old tool call with its long string arguments shortened (still valid JSON)."""
    fn = call.get("function") or {}
    raw = fn.get("arguments")
    if not isinstance(raw, str) or len(raw) <= ARG_MAX_CHARS:
        return call
    try:
        args = json.loads(raw)
    except ValueError:
        return call
    return {**call, "function": {**fn, "arguments": json.dumps(_shorten(args), ensure_ascii=False)}}
