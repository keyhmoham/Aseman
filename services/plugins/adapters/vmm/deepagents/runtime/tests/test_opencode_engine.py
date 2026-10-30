"""The OpenCode agentic engine: headless CLI, free models, not the programmer."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from langgraph.checkpoint.memory import InMemorySaver

from aseman_agents.agent import Runner
from aseman_agents.opencode_engine.cli import RunResult, RunSpec, isolated_env, run_argv
from aseman_agents.opencode_engine.config import write_config, app_builder, teammate
from aseman_agents.opencode_engine.engine import OpenCodeEngine, swarm_specs
from aseman_agents.opencode_engine.events import parse_stream
from aseman_agents.opencode_engine.mapping import reject_programmer
from aseman_agents.opencode_engine.models import is_free, select
from aseman_agents.store import Store
from fakes import LEAD, SPACE, ROOM, turn_request


class FakeCLI:
    binary = "opencode"

    def __init__(self, home: Path | None = None, thread: str = "") -> None:
        self.specs: list[RunSpec] = []
        self.home = home
        self.thread = thread
        self.pause = False

    async def run(self, spec: RunSpec) -> RunResult:
        self.specs.append(spec)
        if self.pause and self.home is not None:
            from aseman_agents.opencode_engine.cli import pause_path
            path = pause_path(self.home, self.thread)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({
                "thread": self.thread, "question": "Ship it?", "options": ["Yes", "No"],
            }), encoding="utf-8")
        return RunResult(
            stdout='{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"shipped"}}\n',
            stderr="", code=0,
        )


def test_free_model_selection_ignores_platform_providers() -> None:
    listed = [
        "aseman/default", "openai/gpt-5", "opencode/mimo-v2.6-flash-free",
        "opencode/deepseek-v4.1-flash-free", "opencode/flint-40b-free", "opencode/paid-model",
    ]
    assert not is_free("aseman/default")
    assert not is_free("openai/gpt-5")
    assert not is_free("opencode/paid-model")
    assert is_free("opencode/big-pickle")
    assert select("lead", listed) == "opencode/deepseek-v4.1-flash-free"
    assert select("app", listed) == "opencode/flint-40b-free"
    assert select("handoff", listed) == "opencode/deepseek-v4.1-flash-free"


def test_headless_command_is_isolated_from_the_programmer(tmp_path: Path) -> None:
    home = tmp_path / "home"
    config = tmp_path / "opencode.json"
    env = isolated_env(home, config, {
        "PATH": "/usr/bin",
        "ASEMAN_LLM_BASE_URL": "http://node/deepagents/v1/llm",
        "ASEMAN_LLM_API_KEY": "turn-token",
        "OPENCODE_MODEL": "aseman/default",
        "OPENCODE_CONFIG": "/etc/opencode/opencode.json",
        "OPENAI_API_KEY": "sk-platform",
    })
    assert "ASEMAN_LLM_BASE_URL" not in env
    assert "ASEMAN_LLM_API_KEY" not in env
    assert "OPENAI_API_KEY" not in env
    assert env["OPENCODE_CONFIG"] == str(config)
    assert env["OPENCODE_CONFIG"] != "/etc/opencode/opencode.json"
    assert "OPENCODE_MODEL" not in env
    argv = run_argv(binary="opencode", agent="aseman-lead", model="opencode/big-pickle",
                    directory=str(tmp_path), message="go", session="ses_9")
    assert argv[0] == "opencode"
    assert argv[1] == "run"
    assert "--format" in argv and "json" in argv and "--auto" in argv and "--session" in argv
    assert "aseman/default" not in argv
    with pytest.raises(ValueError):
        run_argv(binary="opencode", agent="a", model="aseman/default", directory=".", message="x")


def test_swarm_is_one_headless_run_per_task(tmp_path: Path) -> None:
    specs = swarm_specs(
        [{"id": "a", "agent": "coder", "task": "write the api"},
         {"id": "b", "agent": "app builder", "task": "build the desk app"}],
        binary_path="opencode", model="opencode/deepseek-v4.1-flash-free",
        home=tmp_path / "home", config=tmp_path / "opencode.json", directory=str(tmp_path),
    )
    assert len(specs) == 2
    assert specs[0].agent == "aseman-coder"
    assert specs[1].agent == "aseman-app-builder"
    assert all(spec.model.startswith("opencode/") for spec in specs)
    assert all(spec.env().get("ASEMAN_ENGINE_SWARM_CHILD") == "1" for spec in specs)
    assert all("aseman/default" not in spec.argv() for spec in specs)


def test_programmer_actions_are_refused() -> None:
    assert reject_programmer("llm", "chat", {})
    assert "opencode_run" in reject_programmer("spaces", "ask", {"tool": "opencode_run", "args": {}})
    assert "appui_create" in reject_programmer("spaces", "ask", {"tool": "appui_create"})
    assert reject_programmer("spaces", "ask", {"tool": "appui_publish", "args": {"dir": "/workspace/appui/a"}}) == ""


def test_config_has_no_platform_provider(tmp_path: Path) -> None:
    home = tmp_path / "home"
    model = "opencode/big-pickle"
    write_config(
        tmp_path / "opencode.json", model=model,
        agents=[
            teammate("aseman", "Leads", "Lead the space.", model, primary=True),
            app_builder("opencode/north-mini-code-free"),
        ],
        mcp_env={
            "ASEMAN_ENGINE_GATEWAY": "http://node/deepagents/v1",
            "ASEMAN_ENGINE_TOKEN": "tok",
            "ASEMAN_ENGINE_PROCESS_HOME": str(home),
            "ASEMAN_ENGINE_HOME": str(tmp_path),
            "ASEMAN_ENGINE_CONFIG": str(tmp_path / "opencode.json"),
            "ASEMAN_ENGINE_DIR": str(tmp_path),
            "ASEMAN_ENGINE_MODEL": model,
            "ASEMAN_ENGINE_THREAD": "t",
        },
    )
    doc = json.loads((tmp_path / "opencode.json").read_text())
    assert "provider" not in doc
    assert doc["model"] == "opencode/big-pickle"
    assert doc["agent"]["aseman-app-builder"]["mode"] == "subagent"
    assert "aseman-appui" in doc["agent"]["aseman-app-builder"]["prompt"]
    assert doc["permission"]["bash"] == "deny"
    assert doc["permission"]["task"] == "allow"


def test_stream_parser_reads_session_text_and_a_question() -> None:
    raw = "\n".join([
        '{"type":"text","sessionID":"ses_9","part":{"type":"text","text":"hello"}}',
        '{"type":"tool_use","part":{"tool":"ask_user","state":{"input":{"question":"Go?","options":["Yes"]}}}}',
    ])
    parsed = parse_stream(raw)
    assert parsed.reply == "hello"
    assert parsed.session == "ses_9"
    assert parsed.ask == "Go?"
    assert parsed.options == ["Yes"]


@pytest.fixture
def platform(tmp_path: Path):
    from fakes import Platform
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"]}
    return p


async def test_a_turn_uses_opencode_and_not_the_platform_llm(platform, tmp_path: Path) -> None:
    def boom(agent, gw):
        raise AssertionError("the platform LLM gateway was called")

    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=boom, gateway_factory=platform.gateway)
    home = tmp_path / "engine"
    thread = f"{LEAD['vm_id']}:{SPACE}:{ROOM}"
    fake = FakeCLI()
    runner._opencode_engine = OpenCodeEngine(
        store, home=home, runner=fake,
        model_lister=lambda: [
            "aseman/default", "openai/gpt-5", "opencode/deepseek-v4-flash-free",
            "opencode/north-mini-code-free", "opencode/mimo-v2.5-free",
        ],
    )
    out = await runner.prompt(turn_request(
        LEAD, "plan the launch", token="tok-lead", role="lead",
        agent_engine="opencode", opencode=True,
    ))
    assert out.status == "done", out
    assert out.reply == "shipped"
    spec = fake.specs[0]
    assert spec.model == "opencode/deepseek-v4-flash-free"
    args = spec.argv()
    assert args[1] == "run"
    assert "--format" in args and "json" in args
    env = spec.env()
    assert "ASEMAN_LLM_BASE_URL" not in env and "ASEMAN_LLM_API_KEY" not in env
    assert env["OPENCODE_CONFIG"].endswith("opencode.json")
    assert "/etc/opencode" not in env["OPENCODE_CONFIG"]
    doc = json.loads(Path(env["OPENCODE_CONFIG"]).read_text())
    assert "provider" not in doc
    assert "aseman-app-builder" in doc["agent"]
    assert doc["agent"]["aseman-app-builder"]["model"] == "opencode/north-mini-code-free"
    assert "aseman-coder" in doc["agent"]
    assert "run_swarm" in spec.message
    assert "aseman-app-builder" in spec.message
    # The programmer switch was on in the request; the engine still did not use its gateway.
    assert "aseman/default" not in args
    assert not any(path.endswith("/llm") for path, _ in platform.calls)

    again = await runner.prompt(turn_request(
        LEAD, "continue", token="tok-lead", role="lead", agent_engine="opencode",
    ))
    assert again.status == "done"
    assert fake.specs[1].session == "ses_1"


async def test_ask_user_pauses_the_opencode_session(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    home = tmp_path / "engine"
    thread = f"{LEAD['vm_id']}:{SPACE}:{ROOM}"
    fake = FakeCLI(home=home, thread=thread)
    fake.pause = True
    runner._opencode_engine = OpenCodeEngine(
        store, home=home, runner=fake, model_lister=lambda: ["opencode/big-pickle"],
    )
    out = await runner.prompt(turn_request(LEAD, "ship?", token="tok-lead", role="lead", agent_engine="opencode"))
    assert out.status == "awaiting"
    assert out.reply.startswith("❓")
    assert "Ship it?" in out.reply
    questions = runner.questions(LEAD["vm_id"], SPACE)
    assert questions and questions[0]["question"] == "Ship it?"
