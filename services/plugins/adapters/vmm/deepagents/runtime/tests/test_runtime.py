from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from langchain_core.messages import AIMessage, ToolMessage
from langgraph.checkpoint.memory import InMemorySaver

from aseman_agents.agent import Runner
from aseman_agents.memory import Settings
from aseman_agents.server import create_app
from aseman_agents.store import Store
from fakes import CODER, LEAD, ROOM, SPACE, FakeViking, Platform, ScriptedModel, call, turn_request

WORKSPACE = Path(os.environ["ASEMAN_WORKSPACE"])


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    return p


def runner(platform: Platform, tmp_path: Path, script: list[Any],
           viking: FakeViking | None = None) -> tuple[Runner, ScriptedModel]:
    model = ScriptedModel(script=script)
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda agent, gw: model,
               gateway_factory=platform.gateway, memory_settings=viking.settings() if viking else Settings())
    return r, model


def tool_results(model: ScriptedModel) -> dict[str, str]:
    out: dict[str, str] = {}
    for convo in model.seen:
        for m in convo:
            if isinstance(m, ToolMessage):
                out[m.name or m.tool_call_id] = str(m.content)
    return out


async def test_lead_plans_works_in_the_sandbox_and_logs(platform: Platform, tmp_path: Path) -> None:
    target = WORKSPACE / "hello.txt"
    r, model = runner(platform, tmp_path, [
        call("write_todos", {"todos": [{"content": "write hello", "status": "in_progress"}]}),
        call("execute", {"command": f"echo hello > {target} && cat {target}"}),
        call("read_file", {"file_path": str(target)}),
        call("send_message", {"body": "hello written"}),
        call("file_send", {"path": str(target), "caption": "the file"}),
        call("ask_weather", {"request": "tomorrow?"}),
        AIMessage(content="Done: hello.txt is in the workspace."),
    ])
    out = await r.prompt(turn_request(LEAD, "write hello", token="tok-lead", role="lead", message_id="m0", codemode=False))
    assert out.status == "done", out
    assert out.reply == "Done: hello.txt is in the workspace."
    assert target.read_text() == "hello\n"
    results = tool_results(model)
    assert "hello" in results["execute"]
    assert "hello" in results["read_file"]
    # Conversation, platform tools and tool bots all went through the platform API.
    assert any(m["body"] == "hello written" and m["sender_id"] == LEAD["account_id"] for m in platform.messages)
    assert {"tool": "file_send", "args": {"path": str(target), "caption": "the file"}, "by": LEAD["account_id"]} in platform.tool_runs
    assert {"bot": "bot-weather", "body": "tomorrow?", "by": LEAD["account_id"]} in platform.tool_runs
    # The work log: the plan, every tool call, and live status.
    texts = [entry.get("text", "") for entry in platform.logs]
    assert any(t.startswith("Plan\n") and "write hello" in t for t in texts)
    assert any(t.startswith("Tool · execute\n") for t in texts)
    assert any(entry.get("status") == "running a command in the sandbox" for entry in platform.logs)
    assert any(entry.get("status") == "waiting for the model" for entry in platform.logs)
    # One write per step: two per model call (waiting, then its answer) and one per tool call.
    calls = sum(isinstance(m, ToolMessage) for m in model.seen[-1])
    assert len(platform.logs) == 2 * len(model.seen) + calls
    # Memory is OpenViking's (see test_memory.py): nothing of it in the sandbox.
    assert not (WORKSPACE / ".aseman/agents/aseman/AGENTS.md").exists()


async def test_model_failure_is_visible_in_the_work_log(platform: Platform, tmp_path: Path) -> None:
    def fail(_: list[Any]) -> AIMessage:
        raise RuntimeError("provider stream idle timeout after 45s")

    r, _ = runner(platform, tmp_path, [fail])
    out = await r.prompt(turn_request(LEAD, "hello", token="tok-lead", role="lead"))
    assert out.status == "failed"
    assert "provider stream idle timeout" in out.error
    assert any(entry.get("status") == "model request failed" and
               "provider stream idle timeout" in entry.get("text", "") for entry in platform.logs)


async def test_task_delegates_through_room_messages(platform: Platform, tmp_path: Path) -> None:
    platform.responders[CODER["account_id"]] = lambda body: "built it at /workspace/app"
    r, model = runner(platform, tmp_path, [
        call("task", {"description": "Build the app", "subagent_type": "coder"}),
        AIMessage(content="The coder built the app."),
    ])
    out = await r.prompt(turn_request(LEAD, "build an app", token="tok-lead", role="lead"))
    assert out.reply == "The coder built the app."
    handoff = next(m for m in platform.messages if m["mentions"] == [CODER["account_id"]])
    assert handoff["sender_id"] == LEAD["account_id"] and "Build the app" in handoff["body"]
    answer = next(m for m in platform.messages if m["reply_to"] == handoff["id"])
    assert answer["sender_id"] == CODER["account_id"]
    assert "built it at /workspace/app" in tool_results(model)["task"]


async def test_tasks_in_one_step_run_together_and_general_purpose_recruits(platform: Platform, tmp_path: Path) -> None:
    platform.responders[CODER["account_id"]] = lambda body: "tests pass"
    both = AIMessage(content="", tool_calls=[
        {"name": "task", "args": {"description": "run the tests", "subagent_type": "coder"}, "id": "t1", "type": "tool_call"},
        {"name": "task", "args": {"description": "research X", "subagent_type": "general-purpose"}, "id": "gp",
         "type": "tool_call"},
    ])
    r, model = runner(platform, tmp_path, [both, AIMessage(content="all good")])
    # The generalist is recruited on first use; it answers like any agent.
    original = platform.do_spaces_agent_recruit

    def recruit(caller: str, body: dict[str, Any]) -> dict[str, Any]:
        res = original(caller, body)
        platform.responders[res["account_id"]] = lambda b: "X is fine"
        return res

    platform.do_spaces_agent_recruit = recruit  # type: ignore[method-assign]
    out = await r.prompt(turn_request(LEAD, "check things", token="tok-lead", role="lead"))
    assert out.reply == "all good"
    results = [str(m.content) for m in model.seen[-1] if isinstance(m, ToolMessage) and m.name == "task"]
    assert any("tests pass" in r for r in results) and any("X is fine" in r for r in results)
    assert any(b["name"].startswith("generalist") for b in platform.bots)


async def test_ask_user_pauses_until_a_person_answers(platform: Platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [
        call("ask_user", {"question": "Which color?", "options": ["red", "blue"]}),
        lambda messages: AIMessage(content=f"Using {messages[-1].content}"),
    ])
    out = await r.prompt(turn_request(CODER, "paint it", token="tok-coder"))
    assert out.status == "awaiting"
    assert "Which color?" in out.reply
    [q] = r.questions(CODER["vm_id"], "space-1")
    assert q["question"] == "Which color?" and q["options"] == ["red", "blue"] and q["kind"] == "question"

    # A different question id is not this one.
    miss = await r.answer(turn_request(CODER, "blue", token="tok-coder", question_id="nope") | {
        "turn": {**turn_request(CODER, "blue", token="tok-coder")["turn"], "question_id": "nope"}})
    assert not miss.answered

    out = await r.answer(turn_request(CODER, "blue", token="tok-coder"))
    assert out.answered and out.status == "done"
    assert out.reply == "Using ann: blue"
    assert r.questions(CODER["vm_id"], "space-1") == []


async def test_interrupt_on_asks_for_approval(platform: Platform, tmp_path: Path) -> None:
    target = WORKSPACE / "approved.txt"
    r, model = runner(platform, tmp_path, [
        call("execute", {"command": f"touch {target}"}),
        AIMessage(content="created"),
    ])
    out = await r.prompt(turn_request(CODER, "make a file", token="tok-coder", interrupt_on=["execute"]))
    assert out.status == "awaiting" and "May I run" in out.reply
    assert r.questions(CODER["vm_id"], "")[0]["kind"] == "approval"
    assert not target.exists()
    out = await r.answer(turn_request(CODER, "yes", token="tok-coder", interrupt_on=["execute"]))
    assert out.answered and out.reply == "created"
    assert target.exists()


async def test_skills_are_written_to_the_sandbox(platform: Platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")])
    skill = {"name": "Data Viz", "description": "Charts from data", "instructions": "Use matplotlib."}
    out = await r.prompt(turn_request(CODER, "hi", token="tok-coder", skills=[skill]))
    assert out.reply == "ok"
    text = (WORKSPACE / ".aseman/agents/coder/skills/data-viz/SKILL.md").read_text()
    assert 'name: "data-viz"' in text and "Use matplotlib." in text
    # The skill index reached the model's system prompt.
    system = str(model.seen[0][0].content)
    assert "data-viz" in system


async def test_room_catch_up(platform: Platform, tmp_path: Path) -> None:
    platform.post("acc-ann", "the budget is 5k")
    r, model = runner(platform, tmp_path, [AIMessage(content="noted")])
    await r.prompt(turn_request(CODER, "plan it", token="tok-coder"))
    human = [m for m in model.seen[0] if m.type == "human"][-1]
    assert "the budget is 5k" in str(human.content)


def test_server_contract(platform: Platform, tmp_path: Path) -> None:
    model = ScriptedModel(script=[AIMessage(content="hi there")])
    app = create_app(lambda store: Runner(store, InMemorySaver(), model_factory=lambda a, g: model,
                                          gateway_factory=platform.gateway),
                     secret="s3cret", data_dir=str(tmp_path / "data"))
    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 401
        headers = {"X-Aseman-Runtime": "s3cret"}
        assert client.get("/healthz", headers=headers).json() == {"ok": True}
        res = client.post("/v1/turns", headers=headers, json=turn_request(CODER, "hello", token="tok-coder"))
        assert res.json() == {"reply": "hi there", "status": "done", "answered": False, "error": ""}
        assert client.get("/v1/questions", params={"vm": "vm-coder"}, headers=headers).json() == {"questions": []}
        res = client.post("/v1/answers", headers=headers, json=turn_request(CODER, "x", token="tok-coder"))
        assert res.json()["answered"] is False
        res = client.post("/v1/turns", headers=headers, json=turn_request(CODER, "x", token="bad"))
        assert res.json()["status"] == "failed"
        assert client.post("/v1/playbooks/reset", json={}).status_code == 401
        assert client.post("/v1/playbooks/reset", headers=headers, json={}).json() == {"reset": 0}  # no learning
        assert client.post("/v1/rooms/forget", headers=headers, json={"space": "s"}).status_code == 400
        assert client.post("/v1/rooms/forget", json={"space": "s", "room": "r"}).status_code == 401


def _thread(agent: dict[str, Any], room: str = ROOM) -> str:
    return f"{agent['vm_id']}:{SPACE}:{room}"


async def test_a_deleted_room_thread_is_forgotten_by_every_agent(platform: Platform, tmp_path: Path) -> None:
    platform.post("acc-ann", "earlier in the room")
    r, _ = runner(platform, tmp_path, [AIMessage(content="first"), AIMessage(content="second")])
    await r.prompt(turn_request(CODER, "hello", token="tok-coder"))
    other = turn_request(CODER, "elsewhere", token="tok-coder")
    other["turn"]["room_id"] = "room-other"
    await r.prompt(other)
    config = lambda room: {"configurable": {"thread_id": _thread(CODER, room), "checkpoint_ns": ""}}
    assert await r.checkpointer.aget_tuple(config(ROOM)) is not None
    assert r.store.seen(_thread(CODER))

    assert await r.forget_room(SPACE, ROOM) >= 1
    assert await r.checkpointer.aget_tuple(config(ROOM)) is None
    assert r.store.seen(_thread(CODER)) == ""
    # Other rooms keep their conversations.
    assert await r.checkpointer.aget_tuple(config("room-other")) is not None
    assert await r.forget_room(SPACE, "") == 0


async def test_forgetting_a_room_thread_clears_sqlite_checkpoints(platform: Platform, tmp_path: Path) -> None:
    from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

    model = ScriptedModel(script=[AIMessage(content="first")])
    async with AsyncSqliteSaver.from_conn_string(str(tmp_path / "cp.db")) as saver:
        r = Runner(Store(str(tmp_path / "rt.db")), saver, model_factory=lambda a, g: model,
                   gateway_factory=platform.gateway)
        await r.prompt(turn_request(CODER, "hello", token="tok-coder"))
        # A thread the store does not know (e.g. a later generation) is found in the checkpoints.
        r.store.forget_room(SPACE, ROOM)
        config = {"configurable": {"thread_id": _thread(CODER), "checkpoint_ns": ""}}
        assert await saver.aget_tuple(config) is not None
        assert await r.forget_room(SPACE, ROOM) == 1
        assert await saver.aget_tuple(config) is None


def modified_request(message: str, *, no_sandbox: bool = False, no_memory: bool = False, scope: str = "request-1") -> dict[str, Any]:
    req = turn_request(CODER, message, token="tok-coder")
    req["turn"].update(no_sandbox=no_sandbox, no_memory=no_memory, request_scope=scope)
    return req


@pytest.mark.parametrize("no_memory", [False, True])
async def test_sandboxless_requests_never_call_sandbox(platform: Platform, tmp_path: Path, no_memory: bool) -> None:
    platform.post("acc-ann", "previous-room-secret")
    r, model = runner(platform, tmp_path, [AIMessage(content="answered")])
    out = await r.prompt(modified_request("explain this", no_sandbox=True, no_memory=no_memory))
    assert out.reply == "answered", out
    assert not any(name == "spaces.ask" and body.get("bot") == "bot-sandbox" for name, body in platform.calls)
    input_text = "\n".join(str(m.content) for m in model.seen[0] if m.type == "human")
    assert ("previous-room-secret" in input_text) is not no_memory


async def test_fresh_excludes_checkpoints_notes_and_room_history_but_keeps_execute(platform: Platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [AIMessage(content="normal reply"), AIMessage(content="fresh reply")])
    await r.prompt(turn_request(CODER, "previous-checkpoint-secret", token="tok-coder"))
    (WORKSPACE / "AGENTS.md").write_text("saved-memory-secret")
    platform.post("acc-ann", "previous-room-secret")
    platform.calls.clear()
    out = await r.prompt(modified_request("new question", no_memory=True))
    assert out.reply == "fresh reply", out
    text = "\n".join(str(m.content) for m in model.seen[-1])
    assert "previous-checkpoint-secret" not in text
    assert "previous-room-secret" not in text
    assert "saved-memory-secret" not in text
    assert not any(name == "spaces.message_list" for name, _ in platform.calls)
    assert not any(name == "spaces.ask" and body.get("bot") == "bot-sandbox" for name, body in platform.calls)
    model.script += [call("execute", {"command": "printf 'current request result'"}), AIMessage(content="done")]
    out = await r.prompt(modified_request("compute", no_memory=True, scope="request-2"))
    assert out.reply == "done"
    assert "current request result" in tool_results(model)["execute"]
    assert (WORKSPACE / "AGENTS.md").read_text() == "saved-memory-secret"


async def test_modified_request_does_not_resume_older_question(platform: Platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [
        call("ask_user", {"question": "old question"}), AIMessage(content="separate answer"),
        AIMessage(content="old resumed"),
    ])
    first = await r.prompt(turn_request(CODER, "old work", token="tok-coder"))
    assert first.status == "awaiting"
    [old] = r.questions(CODER["vm_id"], "space-1")
    out = await r.prompt(modified_request("new work", no_sandbox=True, no_memory=True))
    assert out.reply == "separate answer"
    assert r.questions(CODER["vm_id"], "space-1")[0]["id"] == old["id"]
    req = turn_request(CODER, "answer", token="tok-coder")
    req["turn"]["question_id"] = old["id"]
    out = await r.answer(req)
    assert out.answered and out.reply == "old resumed"


async def test_answer_preserves_restricted_thread_policy(platform: Platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [
        call("ask_user", {"question": "which option?"}), AIMessage(content="continued"),
    ])
    out = await r.prompt(modified_request("new work", no_sandbox=True, no_memory=True))
    assert out.status == "awaiting"
    [q] = r.questions(CODER["vm_id"], "space-1")
    assert q["no_sandbox"] and q["no_memory"] and q["request_scope"] == "request-1"
    platform.calls.clear()
    req = turn_request(CODER, "option A", token="tok-coder")
    req["turn"]["question_id"] = q["id"]
    out = await r.answer(req)
    assert out.answered and out.reply == "continued"
    assert not any(name == "spaces.message_list" or (name == "spaces.ask" and body.get("bot") == "bot-sandbox") for name, body in platform.calls)


async def test_the_answer_goes_to_the_room_once(platform: Platform, tmp_path: Path) -> None:
    # An agent that tries to answer its message with send_message is told to
    # give its final answer instead, so the room never gets the answer twice.
    r, model = runner(platform, tmp_path, [
        call("send_message", {"body": "Why do programmers prefer dark mode?", "reply_to": "m0"}),
        AIMessage(content="Why do programmers prefer dark mode? Light attracts bugs."),
    ])
    out = await r.prompt(turn_request(LEAD, "tell me a joke", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    assert out.reply == "Why do programmers prefer dark mode? Light attracts bugs."
    assert not [m for m in platform.messages if m["sender_id"] == LEAD["account_id"] and not m["kind"]]
    assert tool_results(model)["send_message"].startswith("Not posted")
    # The message it is working on is shown without an id to reply to.
    first = model.seen[0][-1]
    assert "tell me a joke" in str(first.content) and "m0" not in str(first.content)


async def test_a_message_the_model_can_answer_never_starts_the_computer(platform: Platform, tmp_path: Path) -> None:
    r, _ = runner(platform, tmp_path, [AIMessage(content="Light attracts bugs.")])
    out = await r.prompt(turn_request(LEAD, "tell me a joke", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done" and out.reply == "Light attracts bugs."
    # Its skills were laid out in the project's stored files; no command ran.
    assert not [body for name, body in platform.calls if name == "spaces.ask"]


async def test_without_stored_files_the_computer_serves_them(platform: Platform, tmp_path: Path) -> None:
    platform.stored_files = False
    r, _ = runner(platform, tmp_path, [AIMessage(content="ok")])
    out = await r.prompt(turn_request(LEAD, "hello", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done" and out.reply == "ok"
    assert [body for name, body in platform.calls if name == "spaces.ask"]


async def test_a_new_project_gets_its_computer_on_the_first_command(platform: Platform, tmp_path: Path) -> None:
    platform.has_computer = False
    r, _ = runner(platform, tmp_path, [AIMessage(content="Light attracts bugs.")])
    out = await r.prompt(turn_request(LEAD, "tell me a joke", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done"
    assert not [body for name, body in platform.calls if name == "spaces.ask"]
    # The first command names the computer, and the node creates it then.
    r, model = runner(platform, tmp_path, [call("execute", {"command": "echo hi"}), AIMessage(content="ran")])
    out = await r.prompt(turn_request(LEAD, "run it", token="tok-lead", role="lead", message_id="m1"))
    assert out.status == "done" and "hi" in tool_results(model)["execute"]
    assert [body for name, body in platform.calls if name == "spaces.ask" and body.get("bot") == "sandbox"]


async def test_a_connected_apps_functions_are_tools_of_their_own(platform: Platform, tmp_path: Path) -> None:
    platform.apps = [{"name": "DeepWiki", "kind": "tool", "bot_id": "bot-wiki", "description": "Docs for repositories.", "commands": [
        {"name": "ask_question", "description": "Ask about a repository.",
         "schema": {"type": "object", "properties": {"repoName": {"type": "string"}, "question": {"type": "string"}}, "required": ["repoName", "question"]}},
    ]}]
    platform.app_reply = '{"content": [{"type": "text", "text": "It is a web framework."}]}'
    r, model = runner(platform, tmp_path, [
        call("deepwiki__ask_question", {"repoName": "vercel/next.js", "question": "What is it?"}),
        AIMessage(content="It is a web framework."),
    ])
    out = await r.prompt(turn_request(LEAD, "what is next.js?", token="tok-lead", role="lead", message_id="m0", codemode=False))
    assert out.status == "done", out
    # The node gets the function and its arguments; the agent gets the app's words.
    sent = next(run for run in platform.tool_runs if run.get("bot") == "bot-wiki")
    assert json.loads(sent["body"]) == {"function": "ask_question", "payload": {"repoName": "vercel/next.js", "question": "What is it?"}}
    assert tool_results(model)["deepwiki__ask_question"] == "It is a web framework."


def test_every_agent_is_told_to_present_via_code_mode_platform_paths() -> None:
    from aseman_agents.context import AgentDef
    from aseman_agents.prompts import system_prompt

    for lead in (True, False):
        agent = AgentDef(name="a", bot_id="b", account_id="c", vm_id="d", role="lead" if lead else "")
        prompt = system_prompt(agent, "")
        rule = prompt[prompt.index("## Presenting tools and structured data"):]
        assert "/platform/appui_create" in rule
        assert "/platform/ui_present" in rule
        assert "placement=desk" in rule or "complexity=high" in rule
        assert "Code Mode" in prompt


def test_tool_descriptions_say_how_to_present_their_results() -> None:
    from aseman_agents.tools import presentation_hint

    shown = presentation_hint(
        {"bot_id": "bot-wx", "frontend": "", "commands": [{"name": "weather_report"}]},
        "weather_report",
    )
    assert "/platform/appui_create" in shown and "tool='bot-wx'" in shown
    assert "/platform/ui_present" in shown
    for spec in ({"bot_id": "bot-n", "commands": [{"name": "search"}]}, {"bot_id": "bot-n", "frontend": "static"}):
        hint = presentation_hint(spec, "search")
        assert "/platform/appui_create" in hint and "tool='bot-n'" in hint
        assert "/platform/ui_present" in hint
    bare = presentation_hint({"bot_id": "bot-m"}, None)
    assert "ui_present" in bare or "Markdown" in bare


async def test_a_result_is_shown_in_the_tools_own_frontend(platform: Platform, tmp_path: Path) -> None:
    platform.apps = [{"name": "Weather", "kind": "tool", "bot_id": "bot-wx", "frontend": "static",
                      "description": "Weather anywhere.", "commands": [
                          {"name": "weather_report", "description": "Weather for a city.",
                           "schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}]}]
    platform.app_reply = '{"content": [{"type": "text", "text": "{\\"temp\\": 21}"}]}'
    r, model = runner(platform, tmp_path, [
        call("weather__weather_report", {"city": "New York"}),
        call("appui_create", {"tool": "bot-wx", "title": "Weather", "brief": "Weather dashboard showing temp"}),
        AIMessage(content="Here is New York's weather: mild, 21°."),
    ])
    out = await r.prompt(turn_request(LEAD, "weather in new york?", token="tok-lead", role="lead", message_id="m0", codemode=False))
    assert out.status == "done", out
    assert any(run.get("tool") == "appui_create" for run in platform.tool_runs)
    assert "## Presenting tools and structured data" in str(model.seen[0][0].content)


def test_codemode_survives_an_allow_list() -> None:
    from langchain_core.tools import StructuredTool
    from aseman_agents.tools import filter_allowed

    def tool(name: str) -> StructuredTool:
        return StructuredTool.from_function(func=lambda: "", name=name, description=name)

    # Code Mode is the capability surface; it stays even when allow-lists omit it.
    kept = filter_allowed(
        [tool(n) for n in ["codemode_search", "codemode_execute", "appui_create", "file_send"]],
        ["send_message"],
    )
    assert [t.name for t in kept] == ["codemode_search", "codemode_execute"]


def test_agents_are_told_how_to_keep_the_desk() -> None:
    from aseman_agents.context import AgentDef
    from aseman_agents.prompts import system_prompt

    prompt = system_prompt(AgentDef(name="a", bot_id="b", account_id="c", vm_id="d"), "")
    desk = prompt[prompt.index("## The desk"):]
    for words in ("card windows", "dock", "durable", "x`, `y`, `w`, `h`",
                  "/platform/desk_arrange", "/platform/desk_close"):
        assert words in desk, words


async def test_admins_space_agents_read_the_platform_database(platform: Platform, tmp_path: Path) -> None:
    # The node lists db_tables and db_read only in the platform admins space.
    platform.apps.extend([
        {"name": "db_tables", "kind": "tool", "description": "List the platform database's tables.",
         "parameters": {"type": "object", "properties": {"model": {"type": "string"}}}},
        {"name": "db_read", "kind": "tool", "description": "Read records from the platform database.",
         "parameters": {"type": "object", "properties": {"model": {"type": "string"}, "limit": {"type": "integer"}},
                        "required": ["model"]}},
    ])
    r, model = runner(platform, tmp_path, [
        call("db_tables", {}),
        call("db_read", {"model": "accounts", "limit": 5}),
        AIMessage(content="There are accounts."),
    ])
    out = await r.prompt(turn_request(LEAD, "how many accounts?", token="tok-lead", role="lead", message_id="m0", codemode=False))
    assert out.status == "done", out
    assert {"tool": "db_tables", "args": {}, "by": LEAD["account_id"]} in platform.tool_runs
    assert {"tool": "db_read", "args": {"model": "accounts", "limit": 5}, "by": LEAD["account_id"]} in platform.tool_runs


def test_agents_build_interactive_pages_for_tools() -> None:
    from aseman_agents.context import AgentDef
    from aseman_agents.prompts import system_prompt
    from aseman_agents.tools import presentation_hint

    prompt = system_prompt(AgentDef(name="a", bot_id="b", account_id="c", vm_id="d"), "")
    rule = prompt[prompt.index("## Presenting tools and structured data"):prompt.index("## The desk")]
    for words in ("appui_create", "/platform/appui_create", "/platform/proxy_create", "OpenCode"):
        assert words in rule, words
    hint = presentation_hint({"bot_id": "bot-wx", "frontend": "", "commands": [{"name": "forecast"}]}, "forecast")
    assert "/platform/appui_create" in hint and "tool='bot-wx'" in hint
    assert "/platform/proxy_create" in hint and "tool='bot-wx'" in hint
    native = presentation_hint({"bot_id": "bot-wx", "frontend": ""}, "forecast", via_codemode=False)
    assert "appui_create(brief=" in native and "tool='bot-wx'" in native and "proxy_create(tool='bot-wx'" in native


async def test_agents_see_attached_images_with_code_mode_on(platform: Platform, tmp_path: Path) -> None:
    """read_attachment stays a native tool under Code Mode: the image comes back
    as vision content, not as JSON text clipped by codemode_execute."""
    platform.apps.append({"name": "file_read", "kind": "tool", "description": "Read an attached file.",
                          "parameters": {"type": "object", "properties": {"file_id": {"type": "string"}}}})
    ask = platform.do_spaces_ask

    def do_spaces_ask(caller: str, body: dict[str, Any]) -> dict[str, Any]:
        if body.get("tool") == "file_read":
            platform.tool_runs.append({"tool": "file_read", "args": body.get("args"), "by": caller})
            return {"tool": "file_read", "result": json.dumps({"__multimodal": {
                "text": "file: cat.png", "image_url": "data:image/jpeg;base64,AAAA"}})}
        return ask(caller, body)

    platform.do_spaces_ask = do_spaces_ask
    r, model = runner(platform, tmp_path, [
        call("read_attachment", {"file_id": "file-1"}),
        AIMessage(content="A cat."),
    ])
    req = turn_request(CODER, "what is in this photo?", token="tok-coder", allowed_tools=["send_message"])
    req["turn"]["attachments"] = [{"id": "file-1", "name": "cat.png", "mime": "image/png", "size": 4}]
    out = await r.prompt(req)
    assert out.status == "done", out
    assert {"tool": "file_read", "args": {"file_id": "file-1"}, "by": CODER["account_id"]} in platform.tool_runs
    seen = [m for convo in model.seen for m in convo if isinstance(m, ToolMessage) and m.name == "read_attachment"]
    assert seen and isinstance(seen[-1].content, list), seen
    assert any(b.get("type") == "image_url" and b["image_url"]["url"].startswith("data:image/jpeg;base64,")
               for b in seen[-1].content)


def test_platform_tools_do_not_survive_allow_list_without_codemode() -> None:
    """Desk/platform tools are not CORE when Code Mode owns them; only Code Mode is."""
    from langchain_core.tools import StructuredTool
    from aseman_agents.tools import filter_allowed

    tool = StructuredTool.from_function(func=lambda: "", name="appui_create", description="appui_create")
    assert [t.name for t in filter_allowed([tool], ["file_send"])] == []


def test_long_tool_descriptions_keep_their_usage_and_hint() -> None:
    from aseman_agents.tools import DESCRIPTION_MAX, _app_command_tool

    usage = "Use it like this. " * 300
    spec = {"name": "Board", "bot_id": "bot-board", "commands": [{"name": "draw"}]}
    tool = _app_command_tool(None, "board__draw", spec, {"name": "draw", "description": usage})
    assert usage.strip() in tool.description and "appui_create(brief=" in tool.description and "tool='bot-board'" in tool.description
    long = _app_command_tool(None, "board__draw", spec, {"name": "draw", "description": "x" * (DESCRIPTION_MAX * 2)})
    assert len(long.description) < DESCRIPTION_MAX + 1_000 and "appui_create" in long.description


def test_an_apps_json_answer_becomes_lines() -> None:
    from aseman_agents.tools import _app_result

    def reply(text: str) -> str:
        return json.dumps({"content": [{"type": "text", "text": text}]})

    assert _app_result(reply(json.dumps({"skill": "# Spec\nline 2"}))) == "# Spec\nline 2"
    assert _app_result(reply(json.dumps({"a": "x\ny", "b": "z"}))) == "a:\nx\ny\n\nb: z"
    # Other JSON stays as it is: a large result is made pageable when it goes to a file (economy.reflow).
    long = json.dumps({"items": [{"id": i} for i in range(200)]})
    assert _app_result(reply(long)) == long
    assert _app_result(reply('{"id": 1}')) == '{"id": 1}'
    assert _app_result(reply("plain words")) == "plain words"


async def test_files_are_read_and_changed_without_starting_the_computer(platform: Platform, tmp_path: Path) -> None:
    ws = Path(os.environ["ASEMAN_WORKSPACE"])
    (ws / "src").mkdir(parents=True, exist_ok=True)
    (ws / "src" / "app.py").write_text("one\r\ntwo\r\nthree\r\n")
    r, model = runner(platform, tmp_path, [
        call("read_file", {"file_path": f"{ws}/src/app.py", "offset": 1, "limit": 1}),
        call("edit_file", {"file_path": f"{ws}/src/app.py", "old_string": "two", "new_string": "TWO"}),
        call("write_file", {"file_path": f"{ws}/notes/plan.md", "content": "# Plan"}),
        call("edit_file", {"file_path": f"{ws}/src/app.py", "old_string": "missing", "new_string": "x"}),
        AIMessage(content="done"),
    ])
    out = await r.prompt(turn_request(CODER, "tidy it", token="tok-coder"))
    assert out.status == "done", out
    results = tool_results(model)
    assert "two" in results["read_file"] and "one" not in results["read_file"]
    # The edit kept the file's line endings, as on the computer.
    assert (ws / "src" / "app.py").read_bytes() == b"one\r\nTWO\r\nthree\r\n"
    assert (ws / "notes" / "plan.md").read_text() == "# Plan"
    assert "String not found" in results["edit_file"]
    # Nothing was run on the computer: it stayed asleep.
    assert not [body for name, body in platform.calls if name == "spaces.ask"]



async def test_files_go_through_the_computer_when_not_stored(platform: Platform, tmp_path: Path) -> None:
    platform.stored_files = False
    ws = Path(os.environ["ASEMAN_WORKSPACE"])
    (ws / "lib").mkdir(parents=True, exist_ok=True)
    (ws / "lib" / "a.txt").write_text("alpha\nbeta\n")
    r, model = runner(platform, tmp_path, [
        call("read_file", {"file_path": f"{ws}/lib/a.txt"}),
        call("edit_file", {"file_path": f"{ws}/lib/a.txt", "old_string": "beta", "new_string": "gamma"}),
        AIMessage(content="done"),
    ])
    out = await r.prompt(turn_request(CODER, "edit it", token="tok-coder"))
    assert out.status == "done", out
    assert "beta" in tool_results(model)["read_file"]
    assert (ws / "lib" / "a.txt").read_text() == "alpha\ngamma\n"
    assert [body for name, body in platform.calls if name == "spaces.ask"]


def test_every_agent_hands_development_to_opencode() -> None:
    from aseman_agents.prompts import LEAD as LEAD_PROMPT, common_prompt

    for via_codemode, appui, run in ((True, "/platform/appui_create", "/platform/opencode_run"),
                                     (False, "appui_create", "opencode_run")):
        prompt = common_prompt(via_codemode=via_codemode)
        rule = prompt[prompt.index("## Software development is OpenCode's"):prompt.index("## Presenting")]
        assert appui in rule and run in rule and "never write or edit source code yourself" in rule
    assert "Programming is never a role of the team" in LEAD_PROMPT
