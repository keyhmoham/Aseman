"""A real OpenCode server for the tests, with the runtime's relay and MCP server.

Needs the opencode binary: TRADERA_OPENCODE_BIN, or ``opencode`` on PATH (the
tests that need it are skipped otherwise). TRADERA_OPENCODE_CONFIG_HOME may
name a config home with the plugin SDK pre-installed (as the runtime image
has), so OpenCode does not go to npm on its first project.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import socket
from pathlib import Path
from typing import Any, AsyncIterator

import uvicorn
from fastapi import FastAPI

from tradera_agents import opencode
from tradera_agents.opencode import mcp, relay
from tradera_agents.opencode.server import OpenCodeServer


def opencode_binary() -> str:
    found = os.environ.get("TRADERA_OPENCODE_BIN", "") or shutil.which("opencode") or ""
    return found if found and Path(found).is_file() else ""


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


async def host(data: Path) -> AsyncIterator[opencode.OpenCodeEngine]:
    port = free_port()
    server = OpenCodeServer(data, bin_path=opencode_binary(),
                            config_home=os.environ.get("TRADERA_OPENCODE_CONFIG_HOME", ""))
    engine = opencode.build(data, "test-secret", callback_url=f"http://127.0.0.1:{port}", server=server)
    app = FastAPI()
    app.include_router(relay.router(engine.registry))
    app.include_router(mcp.router(engine.registry))
    web = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", lifespan="off"))
    task = asyncio.create_task(web.serve())
    while not web.started:
        await asyncio.sleep(0.05)
    await engine.start()
    try:
        yield engine
    finally:
        await engine.stop()
        web.should_exit = True
        await task


def tool_names(request: dict[str, Any]) -> list[str]:
    return [t["function"]["name"] for t in request.get("tools") or []]


def system_of(request: dict[str, Any]) -> str:
    first = (request.get("messages") or [{}])[0]
    return first.get("content", "") if first.get("role") == "system" else ""


def tool_results(requests: list[dict[str, Any]]) -> dict[str, str]:
    """Tool name → the last result the model saw for it."""
    out: dict[str, str] = {}
    for req in requests:
        names = {}
        for m in req.get("messages") or []:
            for c in m.get("tool_calls") or []:
                names[c["id"]] = c["function"]["name"]
            if m.get("role") == "tool":
                content = m.get("content")
                if isinstance(content, list):
                    content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
                out[names.get(m.get("tool_call_id"), "?")] = str(content)
    return out
