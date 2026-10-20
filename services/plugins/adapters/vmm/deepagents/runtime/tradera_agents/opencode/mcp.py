"""The agent's tools for OpenCode: an MCP server per project.

OpenCode connects to ``{runtime}/opencode/mcp/{key}`` (MCP over streamable
HTTP, answered as plain JSON) as the server ``tradera``. Its tools are the
tools of the turn working on that project now (runs.TurnRun): the
conversation, delegation and swarm tools, the space's apps and platform tools,
memory, the timeline and the shared sandbox's shell and files — the same
LangChain tools the deepagents engine uses, run in the runtime, with the
turn's token. OpenCode lists them when it connects; the engine reconnects it
when a turn's tools differ from what it listed.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

from .runs import Registry

log = logging.getLogger("tradera.agents.opencode")

PROTOCOL = "2025-06-18"


def _reply(rid: Any, result: Any = None, error: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"jsonrpc": "2.0", "id": rid}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result if result is not None else {}
    return out


def router(registry: Registry) -> APIRouter:
    r = APIRouter()

    async def handle(key: str, msg: dict[str, Any]) -> dict[str, Any] | None:
        method = msg.get("method", "")
        rid = msg.get("id")
        if rid is None:
            return None  # a notification
        params = msg.get("params") or {}
        if method == "initialize":
            return _reply(rid, {"protocolVersion": params.get("protocolVersion") or PROTOCOL,
                                "capabilities": {"tools": {"listChanged": False}},
                                "serverInfo": {"name": "tradera", "version": "1.0.0"}})
        if method == "ping":
            return _reply(rid, {})
        if method == "tools/list":
            return _reply(rid, {"tools": registry.specs(key)})
        if method == "tools/call":
            run = registry.get(key)
            name = str(params.get("name") or "")
            if run is None:
                return _reply(rid, {"content": [{"type": "text", "text": "error: this agent is not working on a turn now"}],
                                    "isError": True})
            args = params.get("arguments") or {}
            meta = params.get("_meta") or {}
            content, failed = await run.call_tool(name, args if isinstance(args, dict) else {},
                                                  str(meta.get("progressToken") or rid))
            return _reply(rid, {"content": content, "isError": failed})
        if method in ("resources/list", "prompts/list"):
            return _reply(rid, {method.split("/")[0]: []})
        return _reply(rid, error={"code": -32601, "message": f"method not found: {method}"})

    @r.post("/opencode/mcp/{key}")
    async def mcp(key: str, request: Request) -> Response:
        if not registry.authorized(key, request.headers.get("authorization", "")):
            return JSONResponse({"error": "bad MCP credential"}, status_code=401)
        body = await request.json()
        if isinstance(body, list):
            replies = [x for x in [await handle(key, m) for m in body if isinstance(m, dict)] if x is not None]
            return JSONResponse(replies) if replies else Response(status_code=202)
        reply = await handle(key, body if isinstance(body, dict) else {})
        return JSONResponse(reply) if reply is not None else Response(status_code=202)

    @r.get("/opencode/mcp/{key}")
    async def no_stream(key: str) -> Response:
        # No server-initiated messages: the client gets its answers inline.
        return Response(status_code=405)

    @r.delete("/opencode/mcp/{key}")
    async def end(key: str) -> Response:
        return Response(status_code=204)

    return r
