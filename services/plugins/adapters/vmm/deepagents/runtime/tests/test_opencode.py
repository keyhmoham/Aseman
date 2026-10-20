"""Agents on the OpenCode engine, end to end: a real OpenCode server runs each
turn's loop, its model is the fake node's LLM endpoint (through the runtime's
relay) and its tools are the runtime's MCP server."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from langgraph.checkpoint.memory import InMemorySaver

from tradera_agents.agent import Runner
from tradera_agents.memory import Settings
from tradera_agents.store import Store
from fakes import CODER, LEAD, FakeViking, Platform, ScriptedModel, say, turn_request, use
from ochost import host, opencode_binary, system_of, tool_names, tool_results

pytestmark = [pytest.mark.skipif(not opencode_binary(), reason="needs the opencode binary"),
              pytest.mark.asyncio(loop_scope="module")]

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])


@pytest_asyncio.fixture(loop_scope="module", scope="module")
async def engine(tmp_path_factory: pytest.TempPathFactory) -> Any:
    async for e in host(tmp_path_factory.mktemp("opencode")):
        yield e


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    return p


def runner(platform: Platform, tmp_path: Path, engine: Any, *, viking: FakeViking | None = None,
           side: list[Any] | None = None) -> Runner:
    model = ScriptedModel(script=list(side or []))
    return Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda agent, gw: model,
                  gateway_factory=platform.gateway, memory_settings=viking.settings() if viking else Settings(),
                  engine=engine)


async def test_lead_plans_works_in_the_sandbox_and_logs(platform: Platform, tmp_path: Path, engine: Any) -> None:
    target = WORKSPACE / "oc-hello.txt"
    platform.llm = [
        use("write_todos", {"todos": [{"content": "write hello", "status": "in_progress"}]}),
        use("execute", {"command": f"echo hello > {target} && cat {target}"}),
        use("read_file", {"file_path": str(target)}),
        use("send_message", {"body": "hello written"}, ("file_send", {"path": str(target), "caption": "the file"})),
        use("ask_weather", {"request": "tomorrow?"}),
        say("Done: oc-hello.txt is in the workspace."),
    ]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(LEAD, "write hello", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    assert out.reply == "Done: oc-hello.txt is in the workspace."
    assert target.read_text() == "hello\n"
    # The model saw the agent's own prompt and tools, under their own names.
    first = platform.llm_requests[0]
    assert system_of(first).startswith("You are tradera.")
    assert "Working directory" not in system_of(first)
    names = tool_names(first)
    assert {"execute", "read_file", "write_file", "send_message", "file_send", "write_todos", "assemble_team",
            "run_swarm", "task", "start_task"} <= set(names)
    assert not any(n.startswith("tradera_") for n in names)
    results = tool_results(platform.llm_requests)
    assert "hello" in results["execute"] and "hello" in results["read_file"]
    # Conversation, platform tools and tool bots went through the platform API.
    assert any(m["body"] == "hello written" and m["sender_id"] == LEAD["account_id"] for m in platform.messages)
    assert {"tool": "file_send", "args": {"path": str(target), "caption": "the file"}, "by": LEAD["account_id"]} in platform.tool_runs
    assert {"bot": "bot-weather", "body": "tomorrow?", "by": LEAD["account_id"]} in platform.tool_runs
    # The work log: the plan, every tool call, and live status.
    texts = [entry.get("text", "") for entry in platform.logs]
    assert any(t.startswith("Plan\n") and "write hello" in t for t in texts)
    assert any(t.startswith("Tool · execute\n") for t in texts)
    assert any(entry.get("status") == "running a command in the sandbox" for entry in platform.logs)
    assert any(entry.get("status") == "waiting for the model" for entry in platform.logs)
    assert r.store.todos(f"{LEAD['vm_id']}:space-1:room-1") == [{"content": "write hello", "status": "in_progress"}]


def user_text(request: dict[str, Any]) -> str:
    out = []
    for m in request.get("messages") or []:
        if m.get("role") == "user":
            c = m.get("content")
            out.append(c if isinstance(c, str) else "".join(p.get("text", "") for p in c if isinstance(p, dict)))
    return "\n".join(out)


async def test_model_failure_is_visible_in_the_work_log(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.llm_status = 400
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "hello", token="tok-coder"))
    assert out.status == "failed"
    assert "provider error 400" in out.error
    assert any(e.get("status") == "model request failed" and "provider error 400" in e.get("text", "") for e in platform.logs)


async def test_ask_user_pauses_until_a_person_answers(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.llm = [use("ask_user", {"question": "Which color?", "options": ["red", "blue"]}),
                    lambda req: say("Using " + user_text(req).splitlines()[-1])]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "paint it", token="tok-coder"))
    assert out.status == "awaiting", out
    assert "Which color?" in out.reply
    [q] = r.questions(CODER["vm_id"], "space-1")
    assert q["question"] == "Which color?" and q["options"] == ["red", "blue"] and q["kind"] == "question"
    # The paused turn made no further model call.
    assert len(platform.llm_requests) == 1
    out = await r.answer(turn_request(CODER, "blue", token="tok-coder"))
    assert out.answered and out.status == "done", out
    assert out.reply == "Using ann: blue"
    assert r.questions(CODER["vm_id"], "space-1") == []
    # The answer continued the same OpenCode session: the question is in its history.
    assert "Which color?" in str(platform.llm_requests[-1]["messages"])


async def test_interrupt_on_asks_for_approval(platform: Platform, tmp_path: Path, engine: Any) -> None:
    target = WORKSPACE / "oc-approved.txt"
    platform.llm = [use("execute", {"command": f"touch {target}"}), say("created")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "make a file", token="tok-coder", interrupt_on=["execute"]))
    assert out.status == "awaiting" and "May I run" in out.reply, out
    assert r.questions(CODER["vm_id"], "")[0]["kind"] == "approval"
    assert not target.exists()
    out = await r.answer(turn_request(CODER, "yes", token="tok-coder", interrupt_on=["execute"]))
    assert out.answered and out.reply == "created", out
    assert target.exists()
    assert "Approved" in user_text(platform.llm_requests[-1])


async def test_a_rejected_call_does_not_run(platform: Platform, tmp_path: Path, engine: Any) -> None:
    target = WORKSPACE / "oc-rejected.txt"
    platform.llm = [use("execute", {"command": f"touch {target}"}), say("understood")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "make a file", token="tok-coder", interrupt_on=["execute"]))
    assert out.status == "awaiting"
    out = await r.answer(turn_request(CODER, "no, not now", token="tok-coder", interrupt_on=["execute"]))
    assert out.answered and out.reply == "understood"
    assert not target.exists()
    assert "Not approved" in user_text(platform.llm_requests[-1])


async def test_task_delegates_through_room_messages(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.responders[CODER["account_id"]] = lambda body: "built it at /workspace/app"
    platform.llm = [use("task", {"description": "Build the app", "subagent_type": "coder"}), say("The coder built the app.")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(LEAD, "build an app", token="tok-lead", role="lead"))
    assert out.reply == "The coder built the app.", out
    handoff = next(m for m in platform.messages if m["mentions"] == [CODER["account_id"]])
    assert handoff["sender_id"] == LEAD["account_id"] and "Build the app" in handoff["body"]
    assert "[task " in handoff["body"]
    assert "built it at /workspace/app" in tool_results(platform.llm_requests)["task"]


async def test_parallel_tool_calls_in_one_step(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.llm = [use("execute", {"command": "echo one"}, ("execute", {"command": "echo two"}),
                        ("send_message", {"body": "working on both"})), say("both ran")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "run both", token="tok-coder"))
    assert out.reply == "both ran", out
    tools = [m for m in platform.llm_requests[-1]["messages"] if m.get("role") == "tool"]
    assert len(tools) == 3
    assert any("one" in str(t["content"]) for t in tools) and any("two" in str(t["content"]) for t in tools)


async def test_the_turn_guard_bounds_model_calls(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.llm = [use("execute", {"command": "echo 1"}), use("execute", {"command": "echo 2"}), say("stopped")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "loop", token="tok-coder", max_turns=3))
    assert out.reply == "stopped", out
    # The last allowed call carried no tools and told the agent to wrap up.
    last = platform.llm_requests[-1]
    assert "tools" not in last
    assert "used all its steps" in user_text(last)
    assert "steps left" in user_text(platform.llm_requests[0])


async def test_repeated_calls_are_pointed_out(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.llm = [use("execute", {"command": "echo same"}) for _ in range(3)] + [say("changed approach")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "go", token="tok-coder"))
    assert out.reply == "changed approach"
    assert "same arguments" in user_text(platform.llm_requests[-1])


async def test_the_decision_model_chooses_tools_and_checks_completion(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.apps = [{"name": f"App{i}", "kind": "tool", "bot_id": f"bot-app{i}", "description": f"app {i}",
                      "commands": [{"name": "run", "description": f"run app {i}", "schema": {}}]} for i in range(10)]

    def decide(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for qid, q in questions.items():
            if "complete" == qid:
                out[qid] = {"probability": 0.1 if "later" in state.get("answer", "") else 0.95}
            elif q["type"] == "boolean":
                out[qid] = {"probability": 0.9 if "app3__run" in q["instructions"] else 0.05}
        return out

    platform.decide = decide
    platform.llm = [say("I will do it later."), say("Done now: app3 ran.")]
    r = runner(platform, tmp_path, engine)
    req = turn_request(CODER, "run app 3", token="tok-coder")
    req["decision"] = {"enabled": True, "model": "jev"}
    out = await r.prompt(req)
    assert out.reply == "Done now: app3 ran.", out
    names = tool_names(platform.llm_requests[0])
    assert "app3__run" in names and "app5__run" not in names and "execute" in names
    assert "Not shown to save space" in user_text(platform.llm_requests[0])
    # The completion check sent the agent back to work once.
    assert "independent check" in user_text(platform.llm_requests[1])
    assert any("completion check" in e.get("text", "") for e in platform.logs)


async def test_the_decision_model_approves_low_risk_calls(platform: Platform, tmp_path: Path, engine: Any) -> None:
    target = WORKSPACE / "oc-auto.txt"
    platform.decide = lambda state, qs: {k: {"probabilities": {"0": 0.99, "1": 0.01, "2": 0.0}} for k in qs}
    platform.llm = [use("execute", {"command": f"touch {target}"}), say("made it")]
    r = runner(platform, tmp_path, engine)
    req = turn_request(CODER, "make a file", token="tok-coder", interrupt_on=["execute"])
    req["decision"] = {"enabled": True, "model": "jev", "auto_approve": True}
    out = await r.prompt(req)
    assert out.status == "done" and out.reply == "made it", out
    assert target.exists()
    assert any("auto-approved" in e.get("text", "") for e in platform.logs)


async def test_an_overflowing_conversation_starts_a_new_session(platform: Platform, tmp_path: Path, engine: Any) -> None:
    import httpx

    overflow = httpx.Response(400, json={"error": {"message": "context_length_exceeded: too long",
                                                   "type": "invalid_request_error", "code": "context_length_exceeded"}})
    r = runner(platform, tmp_path, engine)
    platform.llm = [say("first answer")]
    await r.prompt(turn_request(CODER, "hello", token="tok-coder"))
    thread = f"{CODER['vm_id']}:space-1:room-1"
    first_session = r.store.session(thread)
    # The old conversation no longer fits, whatever OpenCode compacts; a fresh one does.
    step = lambda req: overflow if "first answer" in str(req["messages"]) else say("fresh answer")  # noqa: E731
    platform.llm = [step] * 8
    out = await r.prompt(turn_request(CODER, "again", token="tok-coder"))
    assert out.status == "done" and out.reply == "fresh answer", out
    assert r.store.generation(thread) == 1
    assert r.store.session(thread + ":gen:1") not in ("", first_session)


async def test_memory_notes_and_tools_on_opencode(platform: Platform, tmp_path: Path, engine: Any) -> None:
    viking = FakeViking()
    viking.files[("space-space-1", "viking://resources/space/notes.md")] = "# Space notes\nDeploy with make ship."
    platform.llm = [use("remember", {"note": "ann likes blue", "shared": True}), say("noted")]
    r = runner(platform, tmp_path, engine, viking=viking)
    req = turn_request(CODER, "remember my color", token="tok-coder")
    req["memory"] = {"recall": True, "learn": True}
    out = await r.prompt(req)
    assert out.reply == "noted", out
    system = system_of(platform.llm_requests[0])
    assert "Deploy with make ship." in system and "<agent_memory>" in system
    assert "ann likes blue" in viking.files[("space-space-1", "viking://resources/space/notes.md")]
    await r.recorder.drain()
    assert viking.commits


async def test_timeline_tools_on_opencode(platform: Platform, tmp_path: Path, engine: Any) -> None:
    def timeline(msg: dict[str, Any]) -> dict[str, Any]:
        if msg["method"] == "tools/list":
            return {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [
                {"name": "timeline", "description": "dated entries", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}}}]}}
        return {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "2026-01-01 deployed"}]}}

    import tradera_agents.timeline as tl
    tl._listed = None
    platform.timeline = timeline
    platform.llm = [use("timeline_history", {"name": "deploy"}), say("deployed on new year")]
    r = runner(platform, tmp_path, engine)
    req = turn_request(CODER, "when did we deploy?", token="tok-coder")
    req["timeline"] = True
    out = await r.prompt(req)
    assert out.reply == "deployed on new year", out
    assert "2026-01-01 deployed" in tool_results(platform.llm_requests)["timeline_history"]
    assert "<project_timeline>" in system_of(platform.llm_requests[0])


async def test_sandboxless_request_on_opencode(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.post("acc-ann", "previous-room-secret")
    platform.llm = [say("answered")]
    r = runner(platform, tmp_path, engine)
    req = turn_request(CODER, "explain this", token="tok-coder")
    req["turn"].update(no_sandbox=True, no_memory=True, request_scope="req-9")
    out = await r.prompt(req)
    assert out.reply == "answered", out
    assert "execute" not in tool_names(platform.llm_requests[0])
    assert "previous-room-secret" not in str(platform.llm_requests[0]["messages"])
    assert not any(name == "spaces.ask" and body.get("bot") == "bot-sandbox" for name, body in platform.calls)


async def test_room_catch_up_and_attachments(platform: Platform, tmp_path: Path, engine: Any) -> None:
    platform.post("acc-ann", "the budget is 5k")
    platform.llm = [say("noted")]
    r = runner(platform, tmp_path, engine)
    req = turn_request(CODER, "plan it", token="tok-coder")
    req["turn"]["attachments"] = [{"id": "f1", "name": "brief.txt", "mime": "text/plain", "content": "ship by friday"}]
    await r.prompt(req)
    text = user_text(platform.llm_requests[0])
    assert "the budget is 5k" in text and "ship by friday" in text


async def test_a_cancelled_turn_aborts_its_session(platform: Platform, tmp_path: Path, engine: Any) -> None:
    import asyncio

    started = asyncio.Event()

    def slow(req: dict[str, Any]) -> dict[str, Any]:
        started.set()
        return use("execute", {"command": "sleep 30"})

    platform.llm = [slow, say("never")]
    r = runner(platform, tmp_path, engine)
    task = asyncio.create_task(r.prompt(turn_request(CODER, "sleep", token="tok-coder")))
    await asyncio.wait_for(started.wait(), 20)
    await asyncio.sleep(1.0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert not engine.registry._runs


async def test_a_swarm_of_real_agent_turns_runs_in_parallel(platform: Platform, tmp_path: Path, engine: Any,
                                                            monkeypatch: pytest.MonkeyPatch) -> None:
    """The lead runs a plan with run_swarm; each task is a real turn of the
    coder on OpenCode; the coder takes concurrent tasks as parallel instances."""
    import asyncio

    from tradera_agents import team as teamlib

    monkeypatch.setattr(teamlib, "POLL_EVERY", 0.1)
    r = runner(platform, tmp_path, engine)
    started: list[str] = []

    def model(req: dict[str, Any]) -> dict[str, Any]:
        system = system_of(req)
        said = user_text(req)
        if system.startswith("You are tradera."):
            if "run_swarm" in tool_results([req]):
                return say("Both parts are done:\n" + tool_results([req])["run_swarm"][:2000])
            return use("run_swarm", {"goal": "build a site", "tasks": [
                {"id": "pages", "agent": "coder", "task": "build the pages"},
                {"id": "api", "agent": "coder", "task": "build the api"}]})
        asked = said.split("wrote:\n")[-1]  # the message the turn answers (not the room's catch-up)
        part = "pages" if "build the pages" in asked else "api"
        if "execute" not in tool_results([req]):
            started.append(part)
            return use("execute", {"command": f"echo {part} built"})
        return say(f"{part}: done")

    platform.llm = [model] * 20

    async def coder(body: str, mid: str) -> str:
        out = await r.prompt(turn_request(CODER, body, token="tok-coder", message_id=mid))
        return out.reply

    platform.live[CODER["account_id"]] = coder
    out = await asyncio.wait_for(r.prompt(turn_request(LEAD, "build a site", token="tok-lead", role="lead")), 120)
    assert out.status == "done", out
    assert "pages: done" in out.reply and "api: done" in out.reply
    assert platform.most_working == 2 and sorted(started) == ["api", "pages"]
    # One coder turn ran on its thread in the room, the other as a parallel instance.
    threads = {k for k in engine.projects._written}
    assert len(threads) >= 3  # the lead's, the coder's and the coder's instance


async def test_a_provider_that_cannot_stream(platform: Platform, tmp_path: Path, engine: Any,
                                             monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TRADERA_STREAM", "0")
    platform.llm = [use("execute", {"command": "echo whole"}), say("answered whole")]
    r = runner(platform, tmp_path, engine)
    out = await r.prompt(turn_request(CODER, "go", token="tok-coder"))
    assert out.reply == "answered whole", out
    assert all(not q.get("stream") for q in platform.llm_requests)
    assert "whole" in tool_results(platform.llm_requests)["execute"]


async def test_the_runtimes_http_contract_on_opencode(platform: Platform, tmp_path: Path, engine: Any) -> None:
    import httpx

    from tradera_agents.server import create_app

    platform.llm = [use("ask_user", {"question": "Sure?"}), say("went ahead")]
    app = create_app(lambda store: Runner(store, InMemorySaver(), gateway_factory=platform.gateway, engine=engine),
                     secret="s3cret", data_dir=str(tmp_path / "data"), engine=None)
    headers = {"X-Tradera-Runtime": "s3cret"}
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://rt") as client:
            res = await client.post("/v1/turns", headers=headers, json=turn_request(CODER, "do it", token="tok-coder"))
            assert res.json()["status"] == "awaiting" and "Sure?" in res.json()["reply"]
            qs = (await client.get("/v1/questions", params={"vm": "vm-coder"}, headers=headers)).json()["questions"]
            assert qs and qs[0]["question"] == "Sure?"
            res = await client.post("/v1/answers", headers=headers, json=turn_request(CODER, "yes", token="tok-coder"))
            assert res.json() == {"reply": "went ahead", "status": "done", "answered": True, "error": ""}
