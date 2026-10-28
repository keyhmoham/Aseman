"""Cloudflare Code Mode as the capability-calling system."""

from __future__ import annotations

from pathlib import Path

from langchain_core.messages import AIMessage

from fakes import CODER, Platform, call, turn_request
from test_runtime import platform, runner, tool_results  # noqa: F401


def system_text(model) -> str:
    return "\n".join(str(m.content) for m in model.seen[0] if m.type == "system")


async def test_agents_use_codemode_for_space_apps(platform: Platform, tmp_path: Path) -> None:
    platform.apps = [{"name": "Weather", "kind": "tool", "bot_id": "bot-wx", "description": "Weather.",
                      "commands": [{"name": "weather_report", "description": "Report",
                                    "schema": {"type": "object", "properties": {"city": {"type": "string"}}}}]}]
    r, model = runner(platform, tmp_path, [
        call("codemode_search", {"code": "async () => Object.keys((await codemode.spec()).paths)"}),
        call("codemode_execute", {"code": "async () => ({ ok: true })"}),
        AIMessage(content="Mild in London."),
    ])
    out = await r.prompt(turn_request(CODER, "weather in London?", token="tok-coder") | {"codemode": True})
    assert out.status == "done", out
    assert any(m.get("method") == "tools/call" for m in platform.codemode_calls)
    assert "codemode_search" in tool_results(model)
    assert "codemode_execute" in tool_results(model)
    assert "<code_mode>" in system_text(model)
    assert "weather__weather_report" not in tool_results(model)


async def test_codemode_hides_platform_and_app_tools(platform: Platform, tmp_path: Path) -> None:
    """With Code Mode up, apps and platform tools are not native LLM tools."""
    from aseman_agents import timeline as timeline_mod

    timeline_mod._listed = None
    platform.apps = [{"name": "Weather", "kind": "tool", "bot_id": "bot-wx", "description": "Weather.",
                      "commands": [{"name": "weather_report", "description": "Report",
                                    "schema": {"type": "object", "properties": {"city": {"type": "string"}}}}]}]
    platform.timeline = lambda msg: {
        "jsonrpc": "2.0", "id": msg.get("id", 1),
        "result": {"tools": [{"name": "timeline", "description": "history",
                              "inputSchema": {"type": "object", "properties": {}}}]}
        if msg.get("method") == "tools/list" else {"content": []},
    }
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")])
    out = await r.prompt(turn_request(CODER, "hi", token="tok-coder", timeline=True))
    assert out.status == "done", out
    offered = set(model.offered[0]) if model.offered else set()
    assert "codemode_search" in offered and "codemode_execute" in offered
    assert "file_send" not in offered
    assert "appui_create" not in offered  # reached via /platform/appui_create, not as a native tool
    assert not any(n.startswith("weather__") for n in offered)
    assert not any(n.startswith("timeline_") for n in offered)
    assert "<code_mode>" in system_text(model)
    assert "<project_timeline>" in system_text(model)
    assert "/timeline/" in system_text(model)


async def test_without_codemode_flag_apps_remain_direct_tools(platform: Platform, tmp_path: Path) -> None:
    platform.apps = [{"name": "Weather", "kind": "tool", "bot_id": "bot-wx", "description": "Weather.",
                      "commands": [{"name": "weather_report", "description": "Report",
                                    "schema": {"type": "object", "properties": {"city": {"type": "string"}}}}]}]
    r, model = runner(platform, tmp_path, [
        call("weather__weather_report", {"city": "Paris"}),
        AIMessage(content="Done."),
    ])
    out = await r.prompt(turn_request(CODER, "weather?", token="tok-coder", codemode=False))
    assert out.status == "done", out
    assert platform.codemode_calls == []
    assert "weather__weather_report" in tool_results(model)
    assert "<code_mode_fallback>" not in system_text(model)


async def test_codemode_fallback_when_mcp_down(platform: Platform, tmp_path: Path) -> None:
    """If Code Mode MCP cannot be listed, apps/platform stay as direct tools (visible)."""
    platform.apps = [{"name": "Weather", "kind": "tool", "bot_id": "bot-wx", "description": "Weather.",
                      "commands": [{"name": "weather_report", "description": "Report",
                                    "schema": {"type": "object", "properties": {"city": {"type": "string"}}}}]}]
    platform.codemode = None  # 503 on /codemode/mcp
    r, model = runner(platform, tmp_path, [
        call("weather__weather_report", {"city": "Paris"}),
        AIMessage(content="Done."),
    ])
    out = await r.prompt(turn_request(CODER, "weather?", token="tok-coder"))
    assert out.status == "done", out
    assert "weather__weather_report" in tool_results(model)
    offered = set(model.offered[0]) if model.offered else set()
    assert "codemode_search" not in offered
    assert any(n.startswith("weather__") for n in offered)
    assert "<code_mode_fallback>" in system_text(model)
    assert any("Code Mode unavailable" in (e.get("text") or "") for e in platform.logs)


def test_codemode_prompt_offers_sandbox_agents_and_one_shot() -> None:
    from aseman_agents.codemode import CODEMODE_PROMPT

    for words in ("/sandbox/{op}", "write_files", "exec", "/agents/{name}", "codemode.batch", "One shot first"):
        assert words in CODEMODE_PROMPT, words


def test_one_shot_app_builds_with_codemode_and_opencode_off() -> None:
    from aseman_agents.context import AgentDef
    from aseman_agents.prompts import common_prompt, system_prompt

    prompt = common_prompt(via_codemode=True, opencode=False)
    rule = prompt[prompt.index("## Software development is the space's own"):prompt.index("## Presenting")]
    for words in ("one `codemode_execute`", "/sandbox/write_files", "/sandbox/exec", "/platform/appui_publish",
                  "/agents/{name}"):
        assert words in rule, words
    assert "Prefer one shot" in prompt
    # Without Code Mode there is no one-shot build to describe.
    native = common_prompt(via_codemode=False, opencode=False)
    assert "/sandbox/write_files" not in native and "Prefer one shot" not in native
    # With OpenCode on, OpenCode builds: no agent build flow, but one shot still applies.
    on = common_prompt(via_codemode=True, opencode=True)
    assert "/sandbox/write_files" not in on and "Prefer one shot" in on

    lead = AgentDef(name="a", bot_id="b", account_id="c", vm_id="d", role="lead")
    with_codemode = system_prompt(lead, "", via_codemode=True)
    assert "`/agents/{name}`" in with_codemode and "codemode.batch" in with_codemode
    assert "{lead_codemode}" not in with_codemode
    without = system_prompt(lead, "", via_codemode=False)
    assert "/agents/{name}" not in without and "{lead_codemode}" not in without
