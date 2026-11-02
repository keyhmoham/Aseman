"""Personal Aseman chat through the OpenCode engine (MCP when gateway is set)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from aseman_agents.opencode_engine import config as configlib
from aseman_agents.opencode_engine.engine import OpenCodeEngine, _chat_message
from aseman_agents.opencode_engine.cli import RunResult


def test_chat_message_flattens_turns() -> None:
    text = _chat_message("You are Aseman.", [
        {"role": "user", "content": "Hello"},
        {"role": "assistant", "content": "Hi"},
        {"role": "user", "content": "How are you?"},
    ])
    assert "You are Aseman." in text
    assert "How are you?" in text
    assert "Reply as the assistant" in text


def test_chat_message_with_tools_mentions_account_ops() -> None:
    text = _chat_message("You are Aseman.", [{"role": "user", "content": "list my rooms"}], with_tools=True)
    assert "spaces" in text and "threads" in text
    assert "account_action" in text or "platform_call" in text


def test_write_config_personal_chat_skips_mcp_without_gateway(tmp_path: Path) -> None:
    process = tmp_path / "home"
    process.mkdir()
    agent = configlib.teammate("Aseman", "assistant", "Be brief.", "opencode/flint-40b-free", primary=True)
    cfg = tmp_path / "opencode.json"
    configlib.write_config(
        cfg,
        model="opencode/flint-40b-free",
        agents=[agent],
        mcp_env={"ASEMAN_ENGINE_PROCESS_HOME": str(process)},
        with_mcp=False,
    )
    doc = json.loads(cfg.read_text())
    assert "mcp" not in doc
    assert doc["model"] == "opencode/flint-40b-free"
    assert doc["permission"]["bash"] == "deny"
    assert (process / ".config" / "opencode" / "agents" / f"{agent.name}.md").is_file()


def test_write_config_personal_chat_enables_mcp_with_gateway(tmp_path: Path) -> None:
    process = tmp_path / "home"
    process.mkdir()
    agent = configlib.teammate("Aseman", "assistant", "Be brief.", "opencode/flint-40b-free", primary=True)
    cfg = tmp_path / "opencode.json"
    configlib.write_config(
        cfg,
        model="opencode/flint-40b-free",
        agents=[agent],
        mcp_env={
            "ASEMAN_ENGINE_PROCESS_HOME": str(process),
            "ASEMAN_ENGINE_GATEWAY": "http://node/deepagents/v1",
            "ASEMAN_ENGINE_TOKEN": "tok",
            "ASEMAN_ENGINE_MODE": "personal",
        },
        with_mcp=True,
    )
    doc = json.loads(cfg.read_text())
    assert "mcp" in doc and "aseman-engine" in doc["mcp"]
    assert doc["mcp"]["aseman-engine"]["environment"]["ASEMAN_ENGINE_MODE"] == "personal"


@pytest.mark.asyncio
async def test_opencode_chat_runs_headless(tmp_path: Path) -> None:
    class FakeRunner:
        binary = "opencode"

        async def run(self, spec):
            assert spec.agent.startswith("aseman-")
            assert "opencode/" in spec.model or "opencode-go/" in spec.model
            # One JSON event OpenCode would emit.
            out = json.dumps({
                "type": "text",
                "sessionID": "sess-1",
                "part": {"type": "text", "text": "Hello from OpenCode."},
            }) + "\n"
            return RunResult(stdout=out, stderr="", code=0)

    store_path = tmp_path / "runtime.db"
    from aseman_agents.store import Store

    engine = OpenCodeEngine(Store(str(store_path)), home=tmp_path / "engine", runner=FakeRunner(),
                            model_lister=lambda: ["opencode/flint-40b-free"])
    reply, err = await engine.chat(
        system="You are Aseman.",
        messages=[{"role": "user", "content": "hi"}],
        thread_id="chat:test",
    )
    assert err == ""
    assert "Hello from OpenCode" in reply
