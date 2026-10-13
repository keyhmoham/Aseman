"""The project's timeline, served to agents as a built-in MCP server."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from langchain_core.messages import AIMessage

from tradera_agents import timeline
from fakes import CODER, LEAD, Platform, call, turn_request
from test_runtime import modified_request, platform, runner, tool_results  # noqa: F401

TOOLS = [
    {"name": "timeline", "description": "One entity's dated facts in world-time order.",
     "inputSchema": {"type": "object", "properties": {"entity": {"type": "string"}, "since": {"type": "string"}},
                     "required": ["entity"]}},
    {"name": "changes", "description": "What the graph learned in a window of record time.",
     "inputSchema": {"type": "object", "properties": {"since": {"type": "string"}}}},
    # Utopia's write and manual tools are never offered, even if listed.
    {"name": "remember", "description": "Record one sentence.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "search_docs", "description": "Utopia's manual.", "inputSchema": {"type": "object", "properties": {}}},
]


@pytest.fixture(autouse=True)
def fresh_tool_list() -> None:
    timeline._listed = None


def serve(platform: Platform) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []

    def answer(msg: dict[str, Any]) -> dict[str, Any]:
        if msg["method"] == "tools/list":
            return {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": TOOLS}}
        calls.append(msg["params"])
        text = "coder (#bcoder): 2026-09-01T10:00:00Z ran tool → sandbox_exec [100%]"
        return {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": text}]}}

    platform.timeline = answer
    return calls


def system_text(model) -> str:
    return "\n".join(str(m.content) for m in model.seen[0] if m.type == "system")


async def test_agents_read_the_project_timeline(platform: Platform, tmp_path: Path) -> None:
    calls = serve(platform)
    r, model = runner(platform, tmp_path, [
        call("timeline_history", {"entity": "coder", "since": "2026-09-01"}),
        AIMessage(content="coder ran the sandbox on 1 September."),
    ])
    out = await r.prompt(turn_request(LEAD, "what did coder do this month?", token="tok-lead", role="lead")
                         | {"timeline": True})
    assert out.status == "done", out
    assert calls == [{"name": "timeline", "arguments": {"entity": "coder", "since": "2026-09-01"}}]
    assert "ran tool → sandbox_exec" in tool_results(model)["timeline_history"]
    assert "<project_timeline>" in system_text(model)


async def test_only_read_tools_are_offered(platform: Platform, tmp_path: Path) -> None:
    serve(platform)
    r, model = runner(platform, tmp_path, [call("timeline_remember", {}), AIMessage(content="ok")])
    out = await r.prompt(turn_request(CODER, "remember this", token="tok-coder") | {"timeline": True})
    assert out.status == "done", out
    assert "not a valid tool" in tool_results(model)["timeline_remember"]
    assert not any(m.get("method") == "tools/call" for m in platform.timeline_calls)


async def test_no_timeline_when_the_node_does_not_serve_it(platform: Platform, tmp_path: Path) -> None:
    serve(platform)
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")])
    out = await r.prompt(turn_request(CODER, "hi", token="tok-coder"))
    assert out.reply == "ok", out
    assert platform.timeline_calls == []
    assert "<project_timeline>" not in system_text(model)


async def test_a_fresh_request_reads_no_timeline(platform: Platform, tmp_path: Path) -> None:
    serve(platform)
    r, model = runner(platform, tmp_path, [AIMessage(content="fresh")])
    out = await r.prompt(modified_request("new question", no_memory=True) | {"timeline": True})
    assert out.reply == "fresh", out
    assert platform.timeline_calls == []


async def test_an_unreachable_timeline_does_not_stop_the_turn(platform: Platform, tmp_path: Path) -> None:
    platform.timeline = None  # the node answers 503
    r, model = runner(platform, tmp_path, [AIMessage(content="still here")])
    out = await r.prompt(turn_request(CODER, "hi", token="tok-coder") | {"timeline": True})
    assert out.reply == "still here", out
    assert "<project_timeline>" not in system_text(model)


async def test_a_failing_call_is_reported_to_the_agent(platform: Platform, tmp_path: Path) -> None:
    serve(platform)
    listed = platform.timeline

    def broken(msg: dict[str, Any]) -> dict[str, Any]:
        if msg["method"] == "tools/list":
            return listed(msg)
        return {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": "utopia down"}}

    platform.timeline = broken
    r, model = runner(platform, tmp_path, [call("timeline_changes", {"since": "2026-09-01"}),
                                           AIMessage(content="could not read it")])
    out = await r.prompt(turn_request(CODER, "what changed?", token="tok-coder") | {"timeline": True})
    assert out.status == "done", out
    assert "unavailable" in tool_results(model)["timeline_changes"]
