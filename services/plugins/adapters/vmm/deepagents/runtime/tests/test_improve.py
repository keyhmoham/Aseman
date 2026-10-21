from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import httpx
import pytest
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langgraph.checkpoint.memory import InMemorySaver

from tradera_agents import improve
from tradera_agents.agent import Runner
from tradera_agents.improve import record, replay
from tradera_agents.improve.store import AgentStore
from tradera_agents.store import Store
from fakes import LEAD, SPACE, Platform, ScriptedModel, call, say, turn_request, use

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])
LESSON = "- When a command fails, read its error and change the command; never run it unchanged again."


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"]}
    return p


def ran(name: str, args: dict[str, Any], result: str, cid: str, status: str = "success") -> list[Any]:
    return [AIMessage(content="", tool_calls=[{"name": name, "args": args, "id": cid, "type": "tool_call"}]),
            ToolMessage(content=result, tool_call_id=cid, name=name, status=status)]


def test_a_turn_gives_its_decision_points() -> None:
    messages = [HumanMessage("run the tests"),
                *ran("execute", {"command": "pytest"}, "Error: no module named app\nexit code 1", "c1"),
                *ran("execute", {"command": "pytest"}, "Error: no module named app\nexit code 1", "c2"),
                *ran("execute", {"command": "pytest"}, "Error: no module named app\nexit code 1", "c3"),
                AIMessage(content="I will fix it later.")]
    points = record.points(messages, quality=0.2, complete=0.1)
    kinds = [p["kind"] for p in points]
    assert kinds.count("failure") == 2 and kinds.count("repeat") == 1 and kinds.count("incomplete") == 1
    repeat = next(p for p in points if p["kind"] == "repeat")
    assert repeat["action"] == {"name": "execute", "args": {"command": "pytest"}}
    assert "twice" in repeat["feedback"]
    # The moment is replayable: the conversation before the step, as the model saw it.
    assert repeat["history"][0] == {"role": "user", "content": "run the tests"}
    assert repeat["history"][-1]["role"] == "tool"
    incomplete = next(p for p in points if p["kind"] == "incomplete")
    assert incomplete["action"] == {"text": "I will fix it later."}
    # A turn without problems, that went well, gives what works.
    good = record.points([HumanMessage("list"), *ran("ls", {}, "a b", "c1"), AIMessage(content="a, b")], 0.9, 0.95)
    assert [p["kind"] for p in good] == ["good"]
    # The decision model's judgement after the turn marks a short answer too.
    short = record.points([HumanMessage("make a report"), AIMessage(content="Working on it!")], 0.3, 0.05)
    assert [p["kind"] for p in short] == ["incomplete"]


def test_quality_of_a_turn() -> None:
    class Out:
        def __init__(self, status: str, reply: str = "") -> None:
            self.status, self.reply = status, reply

    errors = [HumanMessage("x"), *ran("execute", {}, "Error: boom", "c1")]
    assert record.quality(Out("failed"), None, [], 1, 10) == 0.0
    assert record.quality(Out("done", "ok"), 1.0, [], 2, 10) > record.quality(Out("done", "ok"), 1.0, errors, 2, 10)
    assert record.quality(Out("done", "ok"), 0.1, [], 2, 10) < 0.5


def test_gather_takes_the_latest_problems_first() -> None:
    turns = [{"request": "old", "tools": ["a"], "points": [{"kind": "failure", "n": 1}, {"kind": "good", "n": 2}]},
             {"request": "new", "tools": ["b"], "points": [{"kind": "repeat", "n": 3}]}]
    points = improve.gather(turns, 10)
    assert [p["n"] for p in points] == [3, 1, 2]
    assert points[0]["request"] == "new" and points[0]["tools"] == ["b"]
    assert [p["n"] for p in improve.gather(turns, 2)] == [3, 1]


def learning(platform: Platform) -> None:
    """The node's learn endpoints for GEPA: the agent repeats a failing command
    unless its playbook says otherwise; the reflection writes that lesson; the
    decision model judges a changed command sound."""

    def model(req: dict[str, Any]) -> dict[str, Any]:
        text = json.dumps(req["messages"])
        if "Write the agent's new playbook" in text:
            return say(f"Here it is:\n```\n{LESSON}\n```")
        if "never run it unchanged again" in text:
            return use("execute", {"command": "pip install -e . && pytest"})
        return use("execute", {"command": "pytest"})

    platform.learn = [model] * 500
    platform.decide = lambda state, questions: {
        "sound": {"value": "pip install" in state["next_step"], "probability":
                  0.9 if "pip install" in state["next_step"] else 0.1}}


def failing_points(n: int) -> list[dict[str, Any]]:
    out = []
    for i in range(n):
        messages = [HumanMessage(f"run the tests of project {i}"),
                    *ran("execute", {"command": "pytest"}, "Error: no module named app\nexit code 1", "c1")]
        for p in record.points(messages, 0.2, None):
            out.append({**p, "request": f"run the tests of project {i}", "tools": ["execute"]})
    return out


EXECUTE = {"type": "function", "function": {"name": "execute", "description": "Run a shell command.", "parameters": {
    "type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}}


def test_gepa_writes_a_playbook_that_avoids_the_known_failures(platform: Platform) -> None:
    learning(platform)
    learn = replay.Learn("http://node", "test-secret", SPACE, LEAD["vm_id"], "m",
                         transport=httpx.MockTransport(platform.handle))
    try:
        best, score, seed = replay.optimize(failing_points(4), playbook="", system="You are an agent.",
                                            tools={"execute": EXECUTE}, learn=learn, budget=30)
    finally:
        learn.close()
    assert LESSON in best
    assert seed == 0.0 and score > 0.8
    # Every call was the project's learning: the runtime's credential, the space and the agent.
    assert platform.learn_requests and all(r["space"] == SPACE and r["agent"] == LEAD["vm_id"]
                                           for r in platform.learn_requests)
    # The replayed agent had its tools and the playbook in its system prompt.
    replays = [r for r in platform.learn_requests if r.get("tools")]
    assert replays[0]["tools"][0]["function"]["name"] == "execute"
    assert any(LESSON in r["messages"][0]["content"] for r in replays)


def test_the_judge_falls_back_to_the_agents_model(platform: Platform) -> None:
    platform.learn = [say('{"probability": 0.8, "why": "it changes the command"}')]
    learn = replay.Learn("http://node", "test-secret", SPACE, LEAD["vm_id"],
                         transport=httpx.MockTransport(platform.handle))
    point = failing_points(1)[0]
    try:
        assert replay.Judge(learn, learn.chat()).sound(point, {"name": "execute", "args": {"command": "ls"}}) == 0.8
    finally:
        learn.close()
    assert not learn.decision_on  # the decision model is off (409): asked no more this cycle


def test_rollout_replays_with_the_candidate_playbook() -> None:
    model = ScriptedModel(script=[AIMessage(content="done")])
    point = failing_points(1)[0]
    out = replay.rollout_fn(model, "SYSTEM", {"execute": EXECUTE})({"playbook": LESSON}, point)
    sent = model.seen[-1]
    assert isinstance(sent[0], SystemMessage) and sent[0].content.startswith("SYSTEM") and LESSON in sent[0].content
    assert [m.type for m in sent[1:]] == ["human"]
    assert replay.step_of(out["messages"][-1]) == {"text": "done"}


async def test_agents_learn_from_their_turns_and_use_their_playbook(platform: Platform, tmp_path: Path) -> None:
    learning(platform)
    improver = improve.Improver(tmp_path / "improve", "http://node", "test-secret",
                                improve.Settings(every=1, cooldown=0, budget=20, min_points=1),
                                transport=httpx.MockTransport(platform.handle))
    model = ScriptedModel(script=[
        call("execute", {"command": "exit 3"}, "c1"),
        call("execute", {"command": "exit 3"}, "c2"),
        AIMessage(content="The command fails."),
        AIMessage(content="Second answer."),
    ])
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda agent, gw: model,
               gateway_factory=platform.gateway, improver=improver)
    out = await r.prompt(turn_request(LEAD, "run the check", token="tok-lead", role="lead", message_id="m1"))
    assert out.status == "done", out
    await improver.drain()

    store = AgentStore(tmp_path / "improve", SPACE, LEAD["vm_id"])
    [turn] = store.turns()
    assert turn["request"].endswith("run the check")
    assert [p["kind"] for p in turn["points"]] == ["failure", "failure"]
    assert "execute" in turn["tools"] and "execute" in store.tools()
    assert "## Your playbook" not in store.system()
    book = store.playbook()
    assert book.version == 1 and LESSON in book.text and book.history[0]["evidence"] == 2

    # The next turn runs with the playbook in its system prompt.
    await r.prompt(turn_request(LEAD, "again", token="tok-lead", role="lead", message_id="m2"))
    assert "## Your playbook" in model.seen[-1][0].text and LESSON in model.seen[-1][0].text

    # A request without memory neither uses the playbook nor teaches it.
    fresh = turn_request(LEAD, "fresh", token="tok-lead", role="lead", message_id="m3")
    fresh["turn"]["no_memory"] = True
    await r.prompt(fresh)
    assert "## Your playbook" not in model.seen[-1][0].text
    assert len(store.turns()) == 2


def test_reading_instructions_again_is_a_repeat() -> None:
    messages = [HumanMessage("draw it"), *ran("board__get_instructions", {}, "How to draw.", "c1"),
                *ran("board__draw", {"shape": "box"}, "drawn", "c2"),
                *ran("board__get_instructions", {}, "How to draw.", "c3"),
                AIMessage(content="Drawn.")]
    points = record.points(messages, quality=0.8, complete=0.9)
    [repeat] = [p for p in points if p["kind"] == "repeat"]
    assert repeat["action"]["name"] == "board__get_instructions" and "already been read" in repeat["feedback"]


def test_an_interrupt_result_is_never_replayed_without_its_call() -> None:
    # A turn resumed from an ask_user interrupt opens with the interrupt's
    # result; its call is in the checkpoint before it. Replaying the lone
    # result as a tool message makes the provider reject the call with
    # "the referenced tool call was not found".
    messages = [ToolMessage(content="node-a: Yes, create it", tool_call_id="call_ask", name="ask_user"),
                *ran("board__get_instructions", {}, "How to draw.", "c1"),
                *ran("board__get_instructions", {}, "How to draw.", "c2"),
                AIMessage(content="Drawn.")]
    points = record.points(messages, quality=0.8, complete=0.9)
    for p in points:
        ai = {tc.get("id") for m in p["history"] if m.get("role") == "assistant" for tc in m.get("tool_calls") or []}
        tool = {m.get("tool_call_id") for m in p["history"] if m.get("role") == "tool"}
        assert not (tool - ai), f"dangling tool result in {p['kind']}: {tool - ai}"
    # The interrupt's result is gone from every replay; the rest is intact.
    assert all("call_ask" not in json.dumps(p["history"]) for p in points)


async def test_a_turn_that_looped_is_learned_from_soon(platform: Platform, tmp_path: Path) -> None:
    learning(platform)
    platform.apps = [{"name": "Board", "kind": "tool", "bot_id": "bot-board", "description": "A whiteboard.",
                      "commands": [{"name": "get_instructions", "description": "How to use the board.",
                                    "schema": {"type": "object", "properties": {}}}]}]
    platform.app_reply = '{"content": [{"type": "text", "text": "Draw with shapes."}]}'
    improver = improve.Improver(tmp_path / "improve", "http://node", "test-secret",
                                improve.Settings(every=100, cooldown=10_000, loop_cooldown=0, budget=20, min_points=1),
                                transport=httpx.MockTransport(platform.handle))
    model = ScriptedModel(script=[
        call("execute", {"command": "exit 3"}, "c1"), AIMessage(content="It fails."),
        call("board__get_instructions", {}, "b1"), call("board__get_instructions", {}, "b2"), AIMessage(content="Done."),
        call("execute", {"command": "exit 4"}, "c2"), AIMessage(content="It fails again."),
    ])
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda agent, gw: model,
               gateway_factory=platform.gateway, improver=improver)
    store = AgentStore(tmp_path / "improve", SPACE, LEAD["vm_id"])
    for i, (message, cycles) in enumerate([("run it", 1), ("draw it", 2), ("run it again", 2)]):
        await r.prompt(turn_request(LEAD, message, token="tok-lead", role="lead", message_id=f"m{i}"))
        await improver.drain()
        # A failing turn waits out the cooldown; one that looped does not.
        assert store.state().cycles == cycles, message


def test_old_playbooks_and_turns_are_not_used(tmp_path: Path) -> None:
    store = AgentStore(tmp_path, SPACE, "vm-a")
    book = store.adopt("Read the skill once.", score=0.8, baseline=0.5, evidence=4)
    since, month = improve.LEARNED_SINCE, 30 * 86400.0
    assert book.current(since, month)
    assert not book.current(since, month, now=book.adopted_at + month + 1)  # expired
    assert book.current(since, 0, now=book.adopted_at + 10 * month)  # no age limit
    assert not book.current(book.adopted_at + 1, month)  # learned before the cutoff
    # A playbook written before playbooks recorded when they were adopted is from before the cutoff.
    old = AgentStore(tmp_path, SPACE, "vm-b")
    old.dir.mkdir(parents=True)
    (old.dir / "playbook.json").write_text(json.dumps({"text": "Stop re-reading the skill.", "version": 3}))
    assert not old.playbook().current(since, month)
    # Turns recorded before the cutoff are not learned from.
    store.record({"at": since - 60, "points": []}, "system")
    store.record({"at": since + 60, "points": []}, "system")
    assert [t["at"] for t in store.turns(since=since)] == [since + 60]


def test_reset_forgets_what_agents_learned(tmp_path: Path) -> None:
    learner = improve.Improver(tmp_path, "http://node", "secret")
    for space, agent in (("s1", "a"), ("s1", "b"), ("s2", "a")):
        store = AgentStore(tmp_path, space, agent)
        store.adopt("lesson", score=0.8, baseline=0.5, evidence=4)
        store.record({"at": improve.LEARNED_SINCE + 60, "points": []}, "system")
    assert learner.reset("s1", "a") == 1
    assert AgentStore(tmp_path, "s1", "a").playbook().text == ""
    assert AgentStore(tmp_path, "s1", "a").turns() == []
    assert list(AgentStore(tmp_path, "s1", "a").dir.glob("playbook.reset-*.json"))  # history kept aside
    assert AgentStore(tmp_path, "s1", "b").playbook().text == "lesson"
    assert learner.reset("s1") == 2
    assert learner.reset() == 3
    assert all(AgentStore(tmp_path, s, a).playbook().text == "" for s, a in (("s1", "b"), ("s2", "a")))
