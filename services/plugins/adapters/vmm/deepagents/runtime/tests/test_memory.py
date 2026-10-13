"""The agents' memory in OpenViking."""

from __future__ import annotations

import os
from pathlib import Path

from langchain_core.messages import AIMessage

from tradera_agents import memory
from tradera_agents.context import AgentDef, Turn, TurnContext
from fakes import CODER, LEAD, FakeViking, Platform, call, turn_request
from test_runtime import modified_request, platform, runner, tool_results  # noqa: F401

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])
ACCOUNT = "space-space-1"
LEAD_NOTES = "viking://user/agent-bot-lead/memories/notes.md"


def system_text(model) -> str:
    return "\n".join(str(m.content) for m in model.seen[0] if m.type == "system")


def human_text(model) -> str:
    return "\n".join(str(m.content) for m in model.seen[0] if m.type == "human")


async def test_memory_lives_in_openviking(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.recalled = "- ann prefers tabs over spaces"
    r, model = runner(platform, tmp_path, [
        call("remember", {"note": "deploys go through staging", "shared": True}),
        call("remember", {"note": "ann likes short answers"}, cid="own"),
        call("recall", {"query": "staging"}),
        call("read_memory", {"uri": memory.SPACE_NOTES}),
        AIMessage(content="Noted."),
    ], viking)
    out = await r.prompt(turn_request(LEAD, "remember how we deploy", token="tok-lead", role="lead"))
    assert out.status == "done" and out.reply == "Noted.", out

    # The notes go into the system prompt; what is recalled comes with the message.
    assert "<agent_memory>" in system_text(model) and "# Space notes" in system_text(model)
    assert "# tradera notes" in system_text(model)
    assert "From your memory" in human_text(model) and "ann prefers tabs" in human_text(model)
    context = next(b for _, _, path, b in viking.requests if path == "/api/v1/search/search")
    assert context["query"] == "remember how we deploy"
    assert set(context["exclude_uris"]) == {memory.SPACE_NOTES, LEAD_NOTES}

    # remember writes the space's shared notes or the agent's own.
    assert "- deploys go through staging" in viking.files[(ACCOUNT, memory.SPACE_NOTES)]
    assert "- ann likes short answers" in viking.files[(ACCOUNT, LEAD_NOTES)]
    assert "people.\n- ann likes short answers" in viking.files[(ACCOUNT, LEAD_NOTES)]  # its own line
    results = tool_results(model)
    assert memory.SPACE_NOTES in results["recall"]
    assert "deploys go through staging" in results["read_memory"]

    # The turn is committed to the agent's session of the room, the person as its peer.
    await r.recorder.drain()
    [(key, messages)] = viking.sessions.items()
    assert key[:2] == (ACCOUNT, "agent-bot-lead") and key[2].startswith("room-")
    assert messages[0] == {"role": "user", "content": "ann: remember how we deploy", "peer_id": "acc-ann"}
    assert messages[1] == {"role": "assistant", "content": "Noted."}
    assert viking.commits == [key]
    # Every request was the space's account and the agent's user.
    assert {(a, u) for a, u, _, _ in viking.requests} == {(ACCOUNT, "agent-bot-lead")}
    # Nothing of memory is kept in the sandbox any more.
    assert not (WORKSPACE / ".tradera/agents/tradera/AGENTS.md").exists()


async def test_agents_share_space_notes_but_not_their_own(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.files[(ACCOUNT, memory.SPACE_NOTES)] = "# Space notes\n- the repo is /workspace/app\n"
    viking.files[(ACCOUNT, LEAD_NOTES)] = "# tradera notes\n- lead-only-secret\n"
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")], viking)
    await r.prompt(turn_request(CODER, "where is the repo?", token="tok-coder"))
    assert "the repo is /workspace/app" in system_text(model)
    assert "lead-only-secret" not in system_text(model)
    assert (ACCOUNT, "viking://user/agent-bot-coder/memories/notes.md") in viking.files


async def test_agents_limited_to_some_tools_keep_their_memory(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    r, model = runner(platform, tmp_path, [call("remember", {"note": "keep it short"}), AIMessage(content="ok")], viking)
    await r.prompt(turn_request(LEAD, "hi", token="tok-lead", role="lead", allowed_tools=["file_send"]))
    assert tool_results(model)["remember"] == f"saved to {LEAD_NOTES}"
    assert "- keep it short" in viking.files[(ACCOUNT, LEAD_NOTES)]


async def test_a_fresh_request_never_reaches_openviking(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    r, model = runner(platform, tmp_path, [AIMessage(content="fresh")], viking)
    out = await r.prompt(modified_request("new question", no_memory=True))
    assert out.reply == "fresh"
    await r.recorder.drain()
    assert viking.requests == []
    assert "<agent_memory>" not in system_text(model)


async def test_sandboxless_requests_keep_their_memory(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.recalled = "- the budget is 5k"
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")], viking)
    await r.prompt(modified_request("what is the budget?", no_sandbox=True))
    assert "the budget is 5k" in human_text(model)
    assert not any(name == "spaces.ask" for name, _ in platform.calls)


async def test_notes_kept_in_the_sandbox_start_the_openviking_notes(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    legacy = WORKSPACE / "AGENTS.md"
    before = legacy.read_text() if legacy.exists() else None
    legacy.write_text("# Space notes\n- legacy convention: tabs\n")
    try:
        r, model = runner(platform, tmp_path, [AIMessage(content="ok"), AIMessage(content="ok")], viking)
        await r.prompt(turn_request(LEAD, "hi", token="tok-lead", role="lead"))
        assert viking.files[(ACCOUNT, memory.SPACE_NOTES)] == "# Space notes\n- legacy convention: tabs\n"
        assert "legacy convention: tabs" in system_text(model)
        # Only once: OpenViking's notes are the memory from then on.
        legacy.write_text("# Space notes\n- changed in the sandbox\n")
        await r.prompt(turn_request(LEAD, "hi again", token="tok-lead", role="lead"))
        assert "changed in the sandbox" not in viking.files[(ACCOUNT, memory.SPACE_NOTES)]
        assert not any(name == "spaces.ask" for name, _ in platform.calls)
    finally:
        if before is None:
            legacy.unlink()
        else:
            legacy.write_text(before)


async def test_without_memory_models_notes_still_work(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.files[(ACCOUNT, memory.SPACE_NOTES)] = "# Space notes\n- deploys go through staging\n"
    r, model = runner(platform, tmp_path, [call("recall", {"query": "how do deploys work"}), AIMessage(content="ok")], viking)
    req = turn_request(LEAD, "how do we deploy?", token="tok-lead", role="lead")
    req["memory"] = {"recall": False, "learn": False}  # the admin picked no memory models
    out = await r.prompt(req)
    assert out.reply == "ok"
    await r.recorder.drain()
    paths = [path for _, _, path, _ in viking.requests]
    # Nothing that needs a model is asked for: no recall by meaning, no learning.
    assert "/api/v1/search/search" not in paths and "/api/v1/search/find" not in paths
    assert viking.sessions == {} and viking.commits == []
    # The notes are still in the prompt, and recall searches them by their words.
    assert "deploys go through staging" in system_text(model)
    assert "line 2: - deploys go through staging" in tool_results(model)["recall"]


async def test_a_turn_goes_on_when_openviking_is_down(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.down = True
    r, model = runner(platform, tmp_path, [call("remember", {"note": "x"}), AIMessage(content="still here")], viking)
    out = await r.prompt(turn_request(LEAD, "hello", token="tok-lead", role="lead"))
    assert out.status == "done" and out.reply == "still here", out
    assert tool_results(model)["remember"].startswith("error:")
    await r.recorder.drain()


def test_identities_are_valid_openviking_ids() -> None:
    ctx = TurnContext(gateway=None, agent=AgentDef(name="Data Wiz", bot_id="", account_id="", vm_id="vm/1"),
                      turn=Turn(space_id="sp ace/1", room_id="r#1", message="hi"))
    mem = memory.Memory.for_turn(ctx, memory.Settings(url="http://ov"))
    assert mem.account == "space-sp-ace-1" and mem.user == "agent-Data-Wiz"
    assert mem.session_id == "room-vm-1-sp-ace-1-r-1"
    long = memory._id("room-", "x" * 200)
    assert len(long) <= 70 and long != memory._id("room-", "x" * 199)
    assert memory.Memory.for_turn(ctx, memory.Settings()) is None
    ctx.turn.no_memory = True
    assert memory.Memory.for_turn(ctx, memory.Settings(url="http://ov")) is None
