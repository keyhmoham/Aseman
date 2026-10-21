"""Connected apps' functions, loaded when the agent needs them (apps.py)."""

from __future__ import annotations

import json
from pathlib import Path

from langchain_core.messages import AIMessage, ToolMessage

from aseman_agents import apps
from fakes import call
from test_decision import APPS, platform, request, runner  # noqa: F401


async def test_many_app_functions_are_loaded_on_demand(platform, tmp_path: Path) -> None:
    platform.app_reply = json.dumps({"content": [{"type": "text", "text": "Opened #1."}]})
    r, model = runner(platform, tmp_path, [
        call(apps.LOAD_TOOL, {"apps": ["github"]}),
        call("github__create_issue", {"body": "login bug"}),
        AIMessage(content="Opened #1."),
    ])
    out = await r.prompt(request("Open a github issue for the login bug", decision=False))
    assert out.status == "done" and out.reply == "Opened #1."
    first, second, last = (set(o) for o in model.offered)
    # At first: the agent's own tools and the load tool, no app function.
    assert apps.LOAD_TOOL in first and not {n for n in first if apps.app_of(n)}
    assert {"execute", "read_file", "write_todos", "task", "ask_user"} <= first
    # Loaded: the whole app, from the next call on; the others stay deferred.
    assert {f"github__{c}" for c in APPS["github"]} <= second and "gmail__send_email" not in second
    assert second <= last
    loaded = next(m for m in model.seen[1] if isinstance(m, ToolMessage) and m.name == apps.LOAD_TOOL)
    assert "github__create_issue" in str(loaded.content)


def test_the_load_tool_lists_every_app() -> None:
    from langchain_core.tools import StructuredTool

    def fn(name: str) -> StructuredTool:
        return StructuredTool.from_function(func=lambda: "", name=name, description="[Board] A whiteboard.")

    tools = [fn(f"board__f{i}") for i in range(30)] + [fn("execute")]
    load, middleware = apps.deferral(tools)
    assert len(load) == 1 and len(middleware) == 1
    assert "- board (Board: 30 functions: f0, f1" in load[0].description
    assert "Loaded board" in load[0].invoke({"apps": ["board"]})
    assert load[0].invoke({"apps": ["nope"]}).startswith("error")
    # A handful of functions is simply offered.
    assert apps.deferral(tools[:5]) == ([], [])


def test_what_the_conversation_loaded() -> None:
    messages = [AIMessage(content="", tool_calls=[{"name": apps.LOAD_TOOL, "args": {"apps": ["gmail"]}, "id": "1"},
                                                  {"name": "stripe__get_balance", "args": {}, "id": "2"},
                                                  {"name": "execute", "args": {}, "id": "3"}])]
    assert apps.loaded(messages) == {"gmail", "stripe"}
