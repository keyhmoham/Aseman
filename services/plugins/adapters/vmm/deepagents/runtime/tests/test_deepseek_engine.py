"""The DeepSeek Harness agentic engine: headless dsh with Aseman's plugins mounted."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from langgraph.checkpoint.memory import InMemorySaver

from aseman_agents.agent import Runner
from aseman_agents.deepseek_engine import mcp_server, profile as profilelib
from aseman_agents.deepseek_engine.cli import TOKEN_ENV, RunResult, RunSpec, isolated_env, pause_path, run_argv
from aseman_agents.deepseek_engine.engine import DeepSeekEngine
from aseman_agents.deepseek_engine.events import parse_stream
from aseman_agents.deepseek_engine.mapping import MECHANISMS, reject
from aseman_agents.store import Store
from fakes import CODER, LEAD, ROOM, SPACE, turn_request


def stream(*events: dict) -> str:
    return "\n".join(json.dumps(e) for e in events) + "\n"


OK = stream(
    {"type": "session", "sessionId": "dsh-1", "cwd": "/x"},
    {"type": "status", "phase": "turn_start", "turn": 1},
    {"type": "tool_call", "callId": "c1", "tool": "todo_write",
     "input": {"todos": [{"content": "Draft the plan", "status": "in_progress"},
                         {"content": "Ship", "status": "pending"}]}},
    {"type": "tool_result", "callId": "c1", "status": "completed", "result": "ok"},
    {"type": "tool_call", "callId": "c2", "tool": "mcp__aseman__send_message", "input": {"body": "on it"}},
    {"type": "tool_result", "callId": "c2", "status": "completed", "result": "posted message m1"},
    {"type": "text", "text": "the plan is ready"},
    {"type": "status", "phase": "step_end", "turn": 1, "step": 1, "usage": {"inputTokens": 120, "outputTokens": 30}},
    {"type": "status", "phase": "turn_end", "turn": 1, "reason": {"kind": "completed"}},
    {"type": "final", "sessionId": "dsh-1", "reason": {"kind": "completed"}, "text": "the plan is ready"},
)


class FakeDSH:
    binary = "dsh"

    def __init__(self, home: Path | None = None, thread: str = "") -> None:
        self.specs: list[RunSpec] = []
        self.patches: list[list[dict]] = []
        self.home = home
        self.thread = thread
        self.pause = False
        self.outputs: list[RunResult] = []

    async def run(self, spec: RunSpec) -> RunResult:
        self.specs.append(spec)
        text = spec.patch.read_text()
        self.patches.append(json.loads("\n".join(l for l in text.splitlines() if not l.startswith("#"))))
        if self.pause and self.home is not None:
            path = pause_path(self.home, self.thread)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"thread": self.thread, "question": "Ship it?", "options": ["Yes", "No"]}))
        if self.outputs:
            return self.outputs.pop(0)
        return RunResult(stdout=OK, stderr="", code=0)


@pytest.fixture
def platform(tmp_path: Path):
    from fakes import Platform
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    return p


def row(rows: list[dict], rid: str) -> dict:
    return next(r for r in rows if r.get("id") == rid)


def inserted(rows: list[dict], rid: str) -> dict:
    return next(i for r in rows for i in r.get("insert") or [] if i.get("id") == rid)


# --- the CLI and its stream ------------------------------------------------------


def test_headless_command_resumes_the_session_without_approvals(tmp_path: Path) -> None:
    argv = run_argv(binary="dsh", patch=tmp_path / "p.yml", message="plan it", session="dsh-1")
    assert argv[:3] == ["dsh", "--profile", "headless"]
    assert argv[argv.index("--patch") + 1] == str(tmp_path / "p.yml")
    assert "--json" in argv
    assert argv[argv.index("--approval-policy") + 1] == "never"
    assert argv[argv.index("--session-id") + 1] == "dsh-1"
    assert argv[-1] == "plan it"
    # A task that looks like a flag stays the task.
    assert run_argv(binary="dsh", patch=tmp_path / "p.yml", message="-v")[-2:] == ["--", "-v"]


def test_the_harness_gets_no_node_credentials(tmp_path: Path) -> None:
    env = isolated_env(tmp_path, base={
        "PATH": "/bin", "DEEPSEEK_API_KEY": "node-key", "OPENAI_API_KEY": "k", "ASEMAN_RUNTIME_SECRET": "s",
        "ASEMAN_OPENVIKING_API_KEY": "ov", "PWD": "/app",
    }, extra={TOKEN_ENV: "turn-token"})
    assert env["DSH_HOME"] == str(tmp_path / "dsh")
    assert env["PATH"] == "/bin"
    for key in ("DEEPSEEK_API_KEY", "OPENAI_API_KEY", "ASEMAN_RUNTIME_SECRET", "ASEMAN_OPENVIKING_API_KEY", "PWD"):
        assert key not in env
    assert env[TOKEN_ENV] == "turn-token"


def test_stream_parser_reads_the_run() -> None:
    parsed = parse_stream(OK)
    assert parsed.session == "dsh-1"
    assert parsed.reply == "the plan is ready"
    assert parsed.reason == "completed"
    assert not parsed.error
    assert [s.tool for s in parsed.tools] == ["todo_write", "mcp__aseman__send_message"]
    assert parsed.tools[1].result == "posted message m1"
    assert parsed.todos[0]["status"] == "in_progress"
    assert (parsed.tokens_in, parsed.tokens_out) == (120, 30)


def test_stream_parser_reads_a_failed_turn() -> None:
    parsed = parse_stream(stream(
        {"type": "session", "sessionId": "dsh-2"},
        {"type": "status", "phase": "turn_end", "reason": {"kind": "error", "error": {"message": "HTTP 402: wallet empty"}}},
        {"type": "final", "sessionId": "dsh-2", "reason": {"kind": "error", "error": {"message": "HTTP 402: wallet empty"}}, "text": ""},
    ))
    assert parsed.error == "HTTP 402: wallet empty"
    assert parsed.reply == ""


# --- the profile overlay -----------------------------------------------------------


def test_overlay_routes_the_model_through_the_turn_gateway(monkeypatch) -> None:
    monkeypatch.delenv("ASEMAN_DSH_ENGINE_LLM", raising=False)
    rows = profilelib.build(profilelib.Overlay(
        persona="You are aseman.", mcp_env={"ASEMAN_ENGINE_DIR": "/tmp/x"}, gateway="http://node/deepagents/v1",
        model="deepseek-chat", context_window=64000, lead=True, team=True, teams=profilelib.TEAMS_BUILTIN,
    ))
    route = row(rows, "llm-pi-ai")["config"]["providers"]["aseman"]
    assert route["baseURL"] == "http://node/deepagents/v1/llm"
    assert route["api"] == "openai-completions"
    assert route["apiKeyEnv"] == TOKEN_ENV
    assert route["models"][0] == {"id": "deepseek-chat", "name": "deepseek-chat", "contextWindow": 64000}
    assert row(rows, "agent-default-model")["config"] == {"provider": "aseman", "model": "deepseek-chat"}
    assert row(rows, "llm-deepseek")["disabled"] is True
    assert row(rows, "system-prompt")["config"]["personaPrefix"] == "You are aseman."
    assert row(rows, "agent-team")["config"]["defaultEnabled"] is True
    for rid in ("tool-bash", "tool-fs", "tool-fs-search", "tool-plugin-manager", "web", "tool-web"):
        assert row(rows, rid)["disabled"] is True
    mcp = inserted(rows, "aseman-mcp")
    assert mcp["name"] == "@deepseek-ai/dsh-mcp-client"
    assert mcp["config"]["transport"] == "stdio"
    assert mcp["config"]["serverName"] == "aseman"
    assert mcp["config"]["args"] == ["-m", "aseman_agents.deepseek_engine.mcp_server"]


def test_overlay_mounts_dsh_022_experimental_agent_teams_for_a_lead(tmp_path: Path) -> None:
    overlay = profilelib.Overlay(persona="p", mcp_env={}, gateway="http://node/deepagents/v1", lead=True, team=True,
                                 teams=profilelib.TEAMS_EXPERIMENTAL)
    rows = profilelib.build(overlay, available={"tool-subagent", "tool-subagent-fork", "tool-subagent-control",
                                                "llm-pi-ai", "system-prompt"})
    for rid in profilelib.TEAM_REPLACES:
        assert row(rows, rid)["disabled"] is True
    assert inserted(rows, "agent-team")["name"] == "@deepseek-ai/dsh-experimental-agent-team"
    assert inserted(rows, "tool-agent-team")["config"] == {"freshProvider": "spawn", "forkProvider": "fork"}
    # A specialist (no team) keeps plain subagents.
    overlay.team = False
    rows = profilelib.build(overlay)
    assert not any(r.get("id") == "tool-subagent" for r in rows)
    assert not any(i.get("id") == "agent-team" for r in rows for i in r.get("insert") or [])
    # The packages are found beside the installed dsh (hoisted or nested).
    pkg = tmp_path / "node_modules" / "@deepseek-ai"
    (pkg / "dsh" / "lib").mkdir(parents=True)
    (pkg / "dsh" / "lib" / "bin.js").write_text("")
    assert profilelib.teams_kind(str(pkg / "dsh" / "lib" / "bin.js"), {"tool-subagent"}) == ""
    (pkg / profilelib.TEAM_PACKAGE).mkdir()
    (pkg / profilelib.TEAM_PACKAGE / "package.json").write_text("{}")
    assert profilelib.teams_kind(str(pkg / "dsh" / "lib" / "bin.js"), {"tool-subagent"}) == profilelib.TEAMS_EXPERIMENTAL
    assert profilelib.teams_kind("dsh", {"agent-team", "tool-agent-team"}) == profilelib.TEAMS_BUILTIN


def test_overlay_can_use_the_engines_own_deepseek_key(monkeypatch) -> None:
    monkeypatch.setenv("ASEMAN_DSH_ENGINE_LLM", "deepseek")
    monkeypatch.setenv("ASEMAN_DSH_ENGINE_API_KEY", "sk-engine")
    assert profilelib.llm_mode() == profilelib.LLM_DEEPSEEK
    rows = profilelib.build(profilelib.Overlay(persona="p", mcp_env={}, mode=profilelib.llm_mode(), lead=True))
    assert row(rows, "agent-default-model")["config"] == {"provider": "deepseek-official", "model": "deepseek-v4-pro"}
    assert row(rows, "llm-pi-ai")["disabled"] is True
    monkeypatch.delenv("ASEMAN_DSH_ENGINE_API_KEY")
    # Without a key the engine stays on the platform's models.
    assert profilelib.llm_mode() == profilelib.LLM_GATEWAY


def test_runtime_self_modification_is_refused() -> None:
    assert reject("llm", "chat", {})
    assert "create_plugin" in reject("spaces", "ask", {"tool": "plugin_manager"})
    assert reject("spaces", "ask", {"tool": "appui_create", "args": {"brief": "x"}}) == ""
    names = [name for name, _ in MECHANISMS]
    for mechanism in ("Subagents", "Agent team", "Swarm", "Planning & workflow", "Questions to people",
                      "Memory", "Creator mode / plugin creation", "Task handoff / dispatch"):
        assert mechanism in names


# --- turns ---------------------------------------------------------------------------


async def test_a_turn_runs_on_dsh_with_aseman_plugins(platform, tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("ASEMAN_DSH_ENGINE_LLM", raising=False)

    def boom(agent, gw):
        raise AssertionError("the LangGraph model was built")

    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=boom, gateway_factory=platform.gateway)
    fake = FakeDSH()
    runner._deepseek_engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    out = await runner.prompt(turn_request(LEAD, "plan the launch", token="tok-lead", role="lead",
                                           agent_engine="deepseek", timeline=True))
    assert out.status == "done", out
    assert out.reply == "the plan is ready"
    spec, rows = fake.specs[0], fake.patches[0]
    env = spec.env()
    assert env[TOKEN_ENV] == "tok-lead"
    assert "--session-id" not in spec.argv()
    route = row(rows, "llm-pi-ai")["config"]["providers"]["aseman"]
    assert route["baseURL"] == "http://node/deepagents/v1/llm"
    assert row(rows, "agent-default-model")["config"]["model"] == "test-model"
    persona = row(rows, "system-prompt")["config"]["personaPrefix"]
    assert "You are aseman" in persona and "You lead the space" in persona
    assert "coder" in persona and "delegate_task" in persona and "team_task_create" in persona
    assert "subagent" in persona and "wait_agent" in persona and "run_swarm" not in persona
    assert "memory_remember" in persona
    assert "create_plugin" in persona and "timeline_*" in persona
    # The harness's own memory: its plugin, its loader, the agent's directory as the workdir.
    mem = inserted(rows, "aseman-memory")
    assert mem["name"].endswith("plugins/aseman-memory.mjs")
    assert mem["config"]["agent"] == LEAD["id"] and mem["config"]["agentName"] == "aseman"
    assert spec.directory == str(Path(mem["config"]["root"]) / LEAD["id"])
    loader = row(rows, "agent-instructions")["config"]
    assert loader["projectRootMarkers"] == [".aseman-space"] and loader["instructionFileCandidates"] == ["AGENTS.md"]
    assert row(rows, "agent-team")["config"]["defaultEnabled"] is True
    mcp_env = inserted(rows, "aseman-mcp")["config"]["env"]
    assert mcp_env["ASEMAN_ENGINE_SPACE"] == SPACE and mcp_env["ASEMAN_ENGINE_ROOM"] == ROOM
    assert mcp_env["ASEMAN_ENGINE_TOKEN"] == "tok-lead"
    assert mcp_env["ASEMAN_ENGINE_TIMELINE"] == "1" and mcp_env["ASEMAN_ENGINE_CODEMODE"] == "1"
    assert "plan the launch" in spec.message
    # The work log saw the engine and the plan.
    # No OpenViking: the platform's memory is not this engine's.
    assert "ASEMAN_ENGINE_MEMORY_USER" not in mcp_env and "ASEMAN_OPENVIKING_URL" not in mcp_env
    statuses = [b.get("status") for name, b in platform.calls if name == "spaces.agent_log"]
    assert any(s and s.startswith("DeepSeek Harness") for s in statuses)
    assert "Draft the plan (0/2)" in statuses
    assert spec.patch.stat().st_mode & 0o777 == 0o600

    again = await runner.prompt(turn_request(LEAD, "continue", token="tok-lead", role="lead", agent_engine="deepseek"))
    assert again.status == "done"
    assert fake.specs[1].session == "dsh-1"


async def test_a_session_dsh_lost_is_started_afresh(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    fake = FakeDSH()
    engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    runner._deepseek_engine = engine
    engine._save_session(f"{LEAD['vm_id']}:{SPACE}:{ROOM}", "dsh-gone")
    fake.outputs = [RunResult(stdout="", stderr="Error: unknown session id dsh-gone: no stored Session", code=1)]
    out = await runner.prompt(turn_request(LEAD, "hi", token="tok-lead", agent_engine="deepseek"))
    assert out.status == "done", out
    assert [s.session for s in fake.specs] == ["dsh-gone", ""]


async def test_ask_user_pauses_and_the_answer_resumes_the_session(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    home = tmp_path / "engine"
    thread = f"{LEAD['vm_id']}:{SPACE}:{ROOM}"
    fake = FakeDSH(home=home, thread=thread)
    fake.pause = True
    runner._deepseek_engine = DeepSeekEngine(store, home=home, runner=fake)
    out = await runner.prompt(turn_request(LEAD, "ship?", token="tok-lead", role="lead", agent_engine="deepseek"))
    assert out.status == "awaiting"
    assert "Ship it?" in out.reply and "- Yes" in out.reply
    assert runner.questions(LEAD["vm_id"], SPACE)[0]["question"] == "Ship it?"
    fake.pause = False
    answered = await runner.answer(turn_request(LEAD, "Yes", token="tok-lead", role="lead", agent_engine="deepseek"))
    assert answered.answered and answered.status == "done"
    assert fake.specs[1].session == "dsh-1"
    assert "Ship it?" in fake.specs[1].message and "Yes" in fake.specs[1].message
    assert runner.questions(LEAD["vm_id"], SPACE) == []


async def test_a_failed_dsh_turn_reports_its_error(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    fake = FakeDSH()
    fake.outputs = [RunResult(stdout=stream(
        {"type": "session", "sessionId": "dsh-3"},
        {"type": "final", "sessionId": "dsh-3", "reason": {"kind": "error", "error": {"message": "provider down"}}, "text": ""},
    ), stderr="", code=1)]
    runner._deepseek_engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    out = await runner.prompt(turn_request(LEAD, "go", token="tok-lead", agent_engine="deepseek"))
    assert out.status == "failed"
    assert "provider down" in out.error


async def test_personal_chat_runs_on_the_persons_gateway(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("ASEMAN_DSH_ENGINE_LLM", raising=False)
    store = Store(str(tmp_path / "rt.db"))
    fake = FakeDSH()
    engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    reply, err = await engine.chat(system="Be brief.", messages=[{"role": "user", "content": "hello"}],
                                   thread_id="chat:acc-ann", with_tools=True,
                                   gateway="http://node/deepagents/v1", token="tok-person", account_id="acc-ann")
    assert (reply, err) == ("the plan is ready", "")
    rows = fake.patches[0]
    assert inserted(rows, "aseman-mcp")["config"]["env"]["ASEMAN_ENGINE_MODE"] == "personal"
    assert fake.specs[0].env()[TOKEN_ENV] == "tok-person"
    reply, err = await engine.chat(system="", messages=[{"role": "user", "content": "hi"}], thread_id="t",
                                   with_tools=False)
    assert reply == "" and "gateway" in err


# --- the Aseman MCP bridge --------------------------------------------------------


def bridge_env(monkeypatch, tmp_path: Path, **extra: str) -> None:
    values = {
        "ASEMAN_ENGINE_MODE": "room", "ASEMAN_ENGINE_SPACE": SPACE, "ASEMAN_ENGINE_ROOM": ROOM,
        "ASEMAN_ENGINE_HOME": str(tmp_path), "ASEMAN_ENGINE_THREAD": "thread-1",
        "ASEMAN_ENGINE_TIMELINE": "", "ASEMAN_ENGINE_CODEMODE": "", "ASEMAN_ENGINE_SWARM_CHILD": "",
        "ASEMAN_ENGINE_MEMORY_USER": "", **extra,
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)


def test_bridge_lists_aseman_plugins(platform, tmp_path: Path, monkeypatch) -> None:
    bridge_env(monkeypatch, tmp_path, ASEMAN_ENGINE_CODEMODE="1")
    bridge = mcp_server.Bridge(platform.gateway("http://node/deepagents/v1", "tok-lead"))
    names = {t["name"] for t in bridge.tools()}
    for name in ("send_message", "list_team", "call_space_tool", "recruit_agent", "ask_user", "delegate_task",
                 "create_app", "create_plugin", "publish_app", "platform_call", "codemode_search", "codemode_execute"):
        assert name in names, name
    # Memory and the swarm are the harness's own, not the bridge's.
    assert not names & {"run_swarm", "assemble_team", "remember", "recall", "read_memory", "rewrite_notes"}


def test_bridge_ask_user_writes_the_pause(platform, tmp_path: Path, monkeypatch) -> None:
    bridge_env(monkeypatch, tmp_path)
    bridge = mcp_server.Bridge(platform.gateway("http://node/deepagents/v1", "tok-lead"))
    text, err = bridge.call("ask_user", {"question": "Which city?", "options": ["Paris", "Rome"]})
    assert not err and "Stop now" in text
    data = json.loads(pause_path(tmp_path, "thread-1").read_text())
    assert data == {"thread": "thread-1", "question": "Which city?", "options": ["Paris", "Rome"]}


def test_bridge_creator_mode_goes_through_app_generation(platform, tmp_path: Path, monkeypatch) -> None:
    bridge_env(monkeypatch, tmp_path)
    bridge = mcp_server.Bridge(platform.gateway("http://node/deepagents/v1", "tok-lead"))
    bridge.call("create_plugin", {"name": "Invoices", "purpose": "track invoices", "operations": ["add", "list"]})
    asks = [b for name, b in platform.calls if name == "spaces.ask"]
    assert asks and asks[-1]["tool"] == "appui_create"
    assert asks[-1]["space"] == SPACE
    assert "Invoices" in asks[-1]["args"]["brief"] and "- add" in asks[-1]["args"]["brief"]
    text, err = bridge.call("platform_call", {"namespace": "spaces", "action": "ask",
                                              "body": {"tool": "plugin_manager"}})
    assert err and "create_plugin" in text



async def test_the_harness_brings_its_own_memory(platform, tmp_path: Path) -> None:
    from fakes import FakeViking
    viking = FakeViking()
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway,
                    memory_settings=viking.settings())
    fake = FakeDSH()
    engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    runner._deepseek_engine = engine
    out = await runner.prompt(turn_request(LEAD, "remember how we deploy", token="tok-lead", role="lead",
                                           agent_engine="deepseek", memory={"recall": True, "learn": True}))
    assert out.status == "done", out
    await runner.recorder.drain()
    # OpenViking (the platform's memory) is never touched.
    assert viking.requests == [] and viking.sessions == {}
    # Each agent of a space keeps its own directory in the space's store.
    root = Path(inserted(fake.patches[0], "aseman-memory")["config"]["root"])
    await runner.prompt(turn_request(CODER, "and you?", token="tok-coder", agent_engine="deepseek"))
    coder = inserted(fake.patches[1], "aseman-memory")["config"]
    assert Path(coder["root"]) == root and coder["agent"] == CODER["id"]
    # The platform reads (and edits) the harness's memory.
    (root / "AGENTS.md").write_text("# Space notes\n- ships on fridays\n")
    (root / LEAD["id"]).mkdir(parents=True, exist_ok=True)
    (root / LEAD["id"] / "journal").mkdir(exist_ok=True)
    (root / LEAD["id"] / "journal" / "2026-11-03.md").write_text("## 10:00 UTC — completed\nAsked: deploy\n")
    view = runner.deepseek_memory(SPACE, LEAD["id"])
    assert "ships on fridays" in view["space_notes"]
    assert view["journal"][0]["day"] == "2026-11-03" and LEAD["id"] in view["agents"]
    runner.write_deepseek_memory(SPACE, "# Space notes\n- deploys are on tuesdays", "")
    assert "tuesdays" in (root / "AGENTS.md").read_text()


async def test_a_no_memory_request_keeps_none(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    fake = FakeDSH()
    runner._deepseek_engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    req = turn_request(LEAD, "fresh", token="tok-lead", agent_engine="deepseek")
    req["turn"]["no_memory"] = True
    out = await runner.prompt(req)
    assert out.status == "done"
    rows = fake.patches[0]
    assert row(rows, "agent-instructions")["disabled"] is True
    assert not any(i.get("id") == "aseman-memory" for r in rows for i in r.get("insert") or [])
    assert "freshly" in row(rows, "system-prompt")["config"]["personaPrefix"]


async def test_the_swarm_shows_in_the_work_log(platform, tmp_path: Path) -> None:
    store = Store(str(tmp_path / "rt.db"))
    runner = Runner(store, InMemorySaver(), model_factory=lambda a, g: None, gateway_factory=platform.gateway)
    fake = FakeDSH()
    fake.outputs = [RunResult(stdout=stream(
        {"type": "session", "sessionId": "dsh-s"},
        {"type": "tool_call", "callId": "a", "tool": "subagent", "input": {"description": "price research", "prompt": "x"}},
        {"type": "tool_call", "callId": "b", "tool": "subagent", "input": {"description": "copy draft", "prompt": "y"}},
        {"type": "tool_call", "callId": "c", "tool": "wait_agent", "input": {}},
        {"type": "tool_call", "callId": "d", "tool": "team_task_create", "input": {"subject": "s", "description": "d"}},
        {"type": "final", "sessionId": "dsh-s", "reason": {"kind": "completed"}, "text": "both done"},
    ), stderr="", code=0)]
    runner._deepseek_engine = DeepSeekEngine(store, home=tmp_path / "engine", runner=fake)
    out = await runner.prompt(turn_request(LEAD, "launch", token="tok-lead", role="lead", agent_engine="deepseek"))
    assert out.reply == "both done"
    texts = [b.get("text") for name, b in platform.calls if name == "spaces.agent_log" and b.get("text")]
    assert any("swarm: 2 subagent(s) — price research, copy draft" in t and "team board: 1 task(s)" in t for t in texts)


PLUGIN_DRIVER = r"""
import { pathToFileURL } from 'node:url'
const [plugin, root] = process.argv.slice(2)
const mod = await import(pathToFileURL(plugin).href)
const tools = {}
const listeners = {}
const ctx = {
  tools: { register: t => { tools[t.name] = t } },
  on: (name, fn) => { listeners[name] = fn },
}
mod.apply(ctx, { root, agent: 'bot-lead', agentName: 'aseman' })
const out = {}
out.saved = await tools.memory_remember.execute({ note: 'deploys go   through staging', shared: true })
out.own = await tools.memory_remember.execute({ note: 'ann likes short answers' })
const session = { id: 's1' }
const emit = (type, data) => listeners['session/event'](session, { type, data })
emit('turn/start', { turn: 1 })
emit('user/message', { role: 'user', source: { kind: 'system-prompt' }, content: [{ type: 'text', text: '# notes' }] })
emit('user/message', { role: 'user', content: [{ type: 'text', text: 'how do we deploy?' }] })
emit('tool/call', { name: 'mcp__aseman__send_message', arguments: '{}' })
emit('assistant/message', { message: { role: 'assistant', content: [{ type: 'text', text: 'Through staging.' }] } })
emit('turn/end', { turn: 1, reason: { kind: 'completed' } })
out.search = await tools.memory_search.execute({ query: 'staging deploy' })
out.read = await tools.memory_read.execute({ path: 'AGENTS.md' })
out.escape = await tools.memory_read.execute({ path: '../../etc/passwd' })
out.schema = tools.memory_remember.parameters
console.log(JSON.stringify(out))
"""


def test_the_memory_plugin_keeps_notes_and_journals_turns(tmp_path: Path) -> None:
    import shutil
    import subprocess
    if shutil.which("node") is None:
        pytest.skip("node is not installed")
    driver = tmp_path / "driver.mjs"
    driver.write_text(PLUGIN_DRIVER)
    root = tmp_path / "space"
    done = subprocess.run(["node", str(driver), str(profilelib.MEMORY_PLUGIN), str(root)],
                          capture_output=True, text=True, timeout=60, check=False)
    assert done.returncode == 0, done.stderr
    out = json.loads(done.stdout)
    assert out["saved"] == "saved to the space notes"
    assert "- deploys go through staging" in (root / "AGENTS.md").read_text()
    assert "- ann likes short answers" in (root / "bot-lead" / "AGENTS.md").read_text()
    assert (root / ".aseman-space").exists()
    [journal] = list((root / "bot-lead" / "journal").glob("*.md"))
    text = journal.read_text()
    assert "Asked: how do we deploy?" in text and "# notes" not in text
    assert "Tools: mcp__aseman__send_message" in text and "Answer: Through staging." in text
    assert "AGENTS.md: - deploys go through staging" in out["search"]
    assert "journal" in out["search"]
    assert "staging" in out["read"]
    assert out["escape"].startswith("error")
    assert out["schema"]["required"] == ["note"]
