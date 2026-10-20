"""The language model side of the swarm: one structured question at a time.

Team setup and planning ask the agent's own model (behind the turn's metered
LLM endpoint, so it is billed to the turn like every other call) for a JSON
answer. A call that fails or does not answer in JSON is None: the caller has
a plain fallback for every question it asks.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage

from ..context import TurnContext

log = logging.getLogger("tradera.agents.swarm")

_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.S)


def parse_json(text: str) -> Any | None:
    """The first JSON object or array in a model's answer."""
    text = (text or "").strip()
    candidates = [m.group(1) for m in _FENCE.finditer(text)] + [text]
    for chunk in candidates:
        chunk = chunk.strip()
        for opener, closer in (("{", "}"), ("[", "]")):
            start = chunk.find(opener)
            end = chunk.rfind(closer)
            if start < 0 or end <= start:
                continue
            try:
                return json.loads(chunk[start:end + 1])
            except ValueError:
                continue
    return None


def _text(message: Any) -> str:
    text = getattr(message, "text", None)
    if isinstance(text, str):
        return text
    content = getattr(message, "content", "")
    if isinstance(content, list):
        return "".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return str(content)


async def ask_json(ctx: TurnContext, system: str, prompt: str) -> Any | None:
    """Ask the agent's model one question that it answers in JSON."""
    model = ctx.llm
    if model is None:
        return None
    try:
        answer = await model.ainvoke([SystemMessage(content=system), HumanMessage(content=prompt)])
    except Exception as exc:  # noqa: BLE001 - every question has a fallback
        log.warning("swarm model call failed: %s", exc)
        return None
    out = parse_json(_text(answer))
    if out is None:
        log.info("swarm model answered without JSON: %s", _text(answer)[:200])
    return out
