"""OpenCode's one model provider: a relay to the node, per project.

OpenCode calls ``{runtime}/opencode/llm/{key}/v1/chat/completions`` (an
OpenAI-compatible provider whose base URL names the project); the relay finds
the project's run (runs.py) and sends the call on to the node: an agent's turn
to the turn's metered LLM endpoint with the turn's token, so the node uses the
provider, model, key, pricing and limits the admin configured for the agent
and bills every token to the turn — exactly as for the deepagents engine.
OpenCode holds no provider key and no node credential: only the runtime does.

On the way the run applies its turn guard and decision model and puts the
agent's system prompt in place, and the tool names are translated
(convert.py). Answers stream back as the node streams them (the node shows
the answer in the room as it is written).
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any, AsyncIterator

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import convert
from .runs import PAUSED_REPLY, Registry

log = logging.getLogger("tradera.agents.opencode")

LLM_TIMEOUT = httpx.Timeout(connect=10.0, read=600.0, write=60.0, pool=30.0)


def _error(status: int, message: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "tradera_error"}}, status_code=status)


def _synthetic(text: str, stream: bool) -> Response:
    """A model answer the relay gives itself (the turn waits on people)."""
    out = {"id": f"tradera-{int(time.time() * 1000)}", "object": "chat.completion", "created": int(time.time()),
           "model": "tradera", "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                            "finish_reason": "stop"}],
           "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}
    return _as_stream(out) if stream else JSONResponse(out)


def _as_stream(out: dict[str, Any]) -> StreamingResponse:
    """A whole chat completion as the stream OpenCode asked for (a provider
    that cannot stream: TRADERA_STREAM=0)."""
    base = {k: out.get(k) for k in ("id", "created", "model")}
    choice = (out.get("choices") or [{}])[0] or {}
    delta = dict(choice.get("message") or {"role": "assistant", "content": ""})
    if delta.get("tool_calls"):
        delta["tool_calls"] = [dict(c, index=i) for i, c in enumerate(delta["tool_calls"])]

    def chunk(body: dict[str, Any]) -> str:
        return "data: " + json.dumps({**base, "object": "chat.completion.chunk", **body}) + "\n\n"

    async def gen() -> AsyncIterator[str]:
        yield chunk({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
        yield chunk({"choices": [{"index": 0, "delta": {}, "finish_reason": choice.get("finish_reason") or "stop"}]})
        if out.get("usage"):
            yield chunk({"choices": [], "usage": out["usage"]})
        yield "data: [DONE]\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


class Assembled:
    """A streamed answer put back together (for the work log), while its tool
    names are given back to OpenCode."""

    def __init__(self, translate: bool = True) -> None:
        self.translate = translate
        self.text: list[str] = []
        self.calls: dict[int, dict[str, Any]] = {}

    def delta(self, delta: dict[str, Any]) -> None:
        if isinstance(delta.get("content"), str):
            self.text.append(delta["content"])
        for call in delta.get("tool_calls") or []:
            index = int(call.get("index") or 0)
            seen = index in self.calls
            mine = self.calls.setdefault(index, {"id": "", "function": {"name": "", "arguments": ""}})
            fn = call.get("function") or {}
            if call.get("id"):
                mine["id"] = call["id"]
            if fn.get("name"):
                mine["function"]["name"] += fn["name"]
                if self.translate and (not seen or not mine["function"]["name"][:-len(fn["name"])]):
                    # The name's first piece carries OpenCode's prefix.
                    fn["name"] = convert.to_opencode(fn["name"])
            if fn.get("arguments"):
                mine["function"]["arguments"] += fn["arguments"]

    def message(self) -> dict[str, Any]:
        out: dict[str, Any] = {"role": "assistant", "content": "".join(self.text)}
        if self.calls:
            out["tool_calls"] = [self.calls[i] for i in sorted(self.calls)]
        return out


def router(registry: Registry) -> APIRouter:
    r = APIRouter()

    @r.post("/opencode/llm/{key}/v1/chat/completions")
    async def chat(key: str, request: Request) -> Response:
        if not registry.authorized(key, request.headers.get("authorization", "")):
            return _error(401, "bad relay credential")
        run = registry.get(key)
        if run is None:
            return _error(409, "this agent is not working on a turn now")
        body = await request.json()
        wanted_stream = bool(body.get("stream"))
        prepared = await run.prepare(body, request.headers.get("x-tradera-session", ""))
        if prepared is None:
            return _synthetic(PAUSED_REPLY, wanted_stream)
        stream = bool(prepared.get("stream"))
        url, headers = run.upstream()
        await run.model_started()
        client: httpx.AsyncClient = run.http()
        try:
            resp = await client.send(client.build_request("POST", url, json=prepared, headers=headers,
                                                          timeout=LLM_TIMEOUT), stream=True)
        except httpx.HTTPError as exc:
            await run.model_finished(None, f"the node's model endpoint is unreachable: {exc}")
            return _error(502, f"model endpoint unreachable: {exc}")
        if resp.status_code >= 300:
            data = await resp.aread()
            await resp.aclose()
            await run.model_finished(None, f"HTTP {resp.status_code}: {data[:800].decode(errors='replace')}")
            return Response(data, status_code=resp.status_code,
                            media_type=resp.headers.get("content-type", "application/json"))
        if not stream or "event-stream" not in resp.headers.get("content-type", ""):
            data = await resp.aread()
            await resp.aclose()
            try:
                out = json.loads(data)
            except ValueError:
                await run.model_finished(None, "the model answered with something other than JSON")
                return Response(data, status_code=502)
            message = ((out.get("choices") or [{}])[0] or {}).get("message") or {}
            await run.model_finished(json.loads(json.dumps(message)))
            if run.translate:
                convert.opencode_message(message)
            return _as_stream(out) if wanted_stream else JSONResponse(out)

        async def relay() -> AsyncIterator[str]:
            assembled = Assembled(run.translate)
            error = ""
            try:
                async for line in resp.aiter_lines():
                    if line.startswith("data:"):
                        payload = line[5:].strip()
                        if payload and payload != "[DONE]":
                            try:
                                chunk = json.loads(payload)
                            except ValueError:
                                yield line + "\n"
                                continue
                            for choice in chunk.get("choices") or []:
                                assembled.delta(choice.get("delta") or {})
                            yield "data: " + json.dumps(chunk) + "\n"
                            continue
                    yield line + "\n"
            except httpx.HTTPError as exc:
                error = f"the model's stream broke: {exc}"
                raise
            finally:
                await resp.aclose()
                await run.model_finished(None if error else assembled.message(), error)

        return StreamingResponse(relay(), media_type="text/event-stream")

    return r
