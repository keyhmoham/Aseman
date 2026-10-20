"""The agents' memory in OpenViking."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from langchain_core.messages import AIMessage

from tradera_agents import memory
from tradera_agents.context import AgentDef, Turn, TurnContext
from fakes import CODER, LEAD, FakeViking, Platform, call, turn_request
from test_runtime import modified_request, platform, runner, tool_results  # noqa: F401

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])
ACCOUNT = "space-space-1"
LEAD_NOTES = "viking://user/agent-bot-lead/memories/notes.md"


@pytest.fixture(autouse=True)
def fresh_policies() -> None:
    # Which sessions have their commit policy is kept for the process: each test starts without.
    memory._POLICIES.clear()


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
    # The answer comes with the tools the agent ran on the way.
    parts = messages[1]["parts"]
    assert [p["tool_name"] for p in parts[:-1]] == ["remember", "remember", "recall", "read_memory"]
    assert parts[0]["tool_input"] == {"note": "deploys go through staging", "shared": True}
    assert parts[0]["tool_status"] == "completed" and "saved to" in parts[0]["tool_output"]
    assert parts[-1] == {"type": "text", "text": "Noted."}
    # OpenViking commits the session itself, once enough gathered or the room is quiet.
    assert viking.commits == [] and viking.policies[key] == memory.AUTO_COMMIT
    # Recall is made as the person who asked, within the room's session.
    assert ("/api/v1/search/search", "acc-ann") in viking.actors and ("/api/v1/search/find", "acc-ann") in viking.actors
    assert context["session_id"] == key[2] and context["purpose"] == "chat" and context["query_expansion"] == "auto"
    assert "dedup_turns" not in context  # the conversation starts here: nothing served before is in view
    # Notes are only embedded, not summarized: they go into the prompt whole.
    writes = [b for _, _, path, b in viking.requests if path == "/api/v1/content/write"]
    assert writes and all(w["processing_mode"] == "vectors_only" for w in writes)
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


async def test_a_conversation_that_starts_fresh_begins_from_the_rooms_session(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.archived = "The team chose Postgres for the app."
    r, model = runner(platform, tmp_path, [AIMessage(content="first"), AIMessage(content="second"),
                                           AIMessage(content="third")], viking)
    await r.prompt(turn_request(LEAD, "pick a database", token="tok-lead", role="lead", message_id="m1"))
    await r.recorder.drain()
    # Nothing earlier on the first turn: the room's session does not exist yet.
    assert "Earlier in this room" not in human_text(model)

    # The conversation no longer fit and starts again: it begins from the session.
    base = f"{LEAD['vm_id']}:space-1:room-1"
    r.store.next_generation(base)
    await r.prompt(turn_request(LEAD, "what did we pick?", token="tok-lead", role="lead", message_id="m2"))
    seen = "\n".join(str(m.content) for m in model.seen[-1] if m.type == "human")
    assert "Earlier in this room" in seen and "chose Postgres" in seen
    assert "They: ann: pick a database" in seen and "You: first" in seen
    searches = [b for _, _, path, b in viking.requests if path == "/api/v1/search/search"]
    assert "dedup_turns" not in searches[-1]

    # Within the conversation, recall leaves out what it served in the last turns.
    await r.prompt(turn_request(LEAD, "and why?", token="tok-lead", role="lead", message_id="m3"))
    last = "\n".join(str(m.content) for m in model.seen[-1] if m.type == "human" and "and why?" in str(m.content))
    assert "Earlier in this room" not in last
    searches = [b for _, _, path, b in viking.requests if path == "/api/v1/search/search"]
    assert searches[-1]["dedup_turns"] == memory.DEDUP_MESSAGES


async def test_a_server_without_auto_commit_is_committed_after_every_turn(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.no_auto_commit = True
    r, _ = runner(platform, tmp_path, [AIMessage(content="ok")], viking)
    await r.prompt(turn_request(CODER, "hi", token="tok-coder", message_id="m-solo"))
    await r.recorder.drain()
    assert len(viking.commits) == 1


async def test_attached_text_files_become_the_spaces_resources(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    r, _ = runner(platform, tmp_path, [AIMessage(content="read"), AIMessage(content="again")], viking)
    for i in range(2):
        req = turn_request(LEAD, "see the spec", token="tok-lead", role="lead", message_id=f"m{i}")
        req["turn"]["attachments"] = [{"id": "f1", "name": "spec v2.txt", "mime": "text/plain", "content": "The API is REST."},
                                      {"id": "f2", "name": "photo.png", "mime": "image/png", "image_data": "AAAA"}]
        await r.prompt(req)
        await r.recorder.drain()
    kept = [uri for (acc, uri) in viking.files if uri.startswith(memory.FILES)]
    assert kept == [f"{memory.FILES}/f1-spec-v2.txt"]
    assert viking.files[(ACCOUNT, kept[0])] == "The API is REST."


async def test_memories_can_be_read_in_brief_and_searched_by_time(platform: Platform, tmp_path: Path) -> None:
    viking = FakeViking()
    viking.files[(ACCOUNT, "viking://user/agent-bot-lead/memories/events/launch.md")] = "The launch went well. " * 200
    viking.summaries["viking://user/agent-bot-lead/memories/events/launch.md"] = "The launch, in short."
    r, model = runner(platform, tmp_path, [
        call("read_memory", {"uri": "viking://user/agent-bot-lead/memories/events/launch.md", "detail": "overview"}),
        call("recall", {"query": "launch", "since": "2026-05-01"}),
        AIMessage(content="ok"),
    ], viking)
    await r.prompt(turn_request(LEAD, "how did the launch go?", token="tok-lead", role="lead"))
    assert tool_results(model)["read_memory"] == "The launch, in short."
    find = next(b for _, _, path, b in viking.requests if path == "/api/v1/search/find")
    assert find["since"] == "2026-05-01" and "until" not in find


def test_specialists_at_work_recall_for_their_work() -> None:
    def purpose(role: str, no_sandbox: bool = False) -> str:
        ctx = TurnContext(gateway=None, agent=AgentDef(name="a", bot_id="b", account_id="c", vm_id="v", role=role),
                          turn=Turn(space_id="s", room_id="r", message="hi", sender_id="acc-1", no_sandbox=no_sandbox))
        return memory.Memory.for_turn(ctx, memory.Settings(url="http://ov")).purpose

    assert purpose("") == "coding" and purpose("lead") == "chat" and purpose("", no_sandbox=True) == "chat"
