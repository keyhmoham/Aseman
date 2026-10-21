from __future__ import annotations

import json
from pathlib import Path

from langchain_core.exceptions import ContextOverflowError
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from tradera_agents import economy, guard, memory
from tradera_agents.agent import _is_overflow
from fakes import LEAD, call, turn_request
from test_runtime import platform, runner  # noqa: F401

IMAGE = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}


def notes_seen(model) -> list[str]:
    return [str(m.content) for convo in model.seen for m in convo
            if isinstance(m, HumanMessage) and str(m.content).startswith(guard.NOTE)]


async def test_a_looping_agent_ends_its_turn_with_an_answer(platform, tmp_path: Path) -> None:
    # The model would poll forever: the turn ends after its budget, with an
    # answer instead of a recursion error.
    r, model = runner(platform, tmp_path, [call("read_room", {"limit": 5}, cid=f"r{i}") for i in range(100)])
    out = await r.prompt(turn_request(LEAD, "loop", token="tok-lead", role="lead", message_id="m0", max_turns=12))
    assert out.status == "done", out
    assert out.reply and "ran out of steps" in out.reply
    assert len(model.seen) == 12
    seen = notes_seen(model)
    assert any("same arguments" in n for n in seen)
    assert any("steps left" in n for n in seen)
    assert "used all its steps" in seen[-1]


async def test_max_turns_counts_model_calls_not_graph_steps(platform, tmp_path: Path) -> None:
    # Before, max_turns=8 allowed 26 graph steps: about four model calls.
    steps = [call("execute", {"command": f"echo {i}"}, cid=f"e{i}") for i in range(6)]
    r, model = runner(platform, tmp_path, [*steps, AIMessage(content="all done")])
    out = await r.prompt(turn_request(LEAD, "work", token="tok-lead", role="lead", message_id="m0", max_turns=8))
    assert out.status == "done", out
    assert out.reply == "all done"


def test_repeats_and_polling_are_noticed() -> None:
    same = [AIMessage(content="", tool_calls=[{"name": "execute", "args": {"command": "ls"}, "id": f"c{i}"}])
            for i in range(3)]
    found = guard.notes([HumanMessage("go"), *same], 3, 100)
    assert any("execute" in n and "same arguments" in n for n in found)
    polls = [AIMessage(content="", tool_calls=[{"name": "read_room", "args": {"limit": i + 1}, "id": f"p{i}"}])
             for i in range(guard.POLLS)]
    assert any("poll" in n for n in guard.notes([HumanMessage("go"), *polls], 6, 100))
    # What came before the person's latest message is another run.
    assert guard.notes([*same, HumanMessage("new")], 1, 100) == []


async def test_a_conversation_that_no_longer_fits_starts_fresh(platform, tmp_path: Path) -> None:
    def answer(messages):
        if any("first request" in str(m.content) for m in messages):
            raise ContextOverflowError("context limit exceeded")
        return AIMessage(content="fresh answer")

    r, model = runner(platform, tmp_path, [AIMessage(content="ok"), answer, answer, answer, answer])
    first = await r.prompt(turn_request(LEAD, "first request", token="tok-lead", role="lead", message_id="m1"))
    assert first.status == "done"
    out = await r.prompt(turn_request(LEAD, "second request", token="tok-lead", role="lead", message_id="m2"))
    assert out.status == "done", out
    assert out.reply == "fresh answer"
    base = f"{LEAD['vm_id']}:space-1:room-1"
    assert r.store.generation(base) == 1
    # Later turns stay on the new conversation.
    nxt = await r.prompt(turn_request(LEAD, "third request", token="tok-lead", role="lead", message_id="m3"))
    assert nxt.status == "done" and nxt.reply == "fresh answer"
    assert r.store.generation(base) == 1


def test_overflow_errors_are_recognized() -> None:
    assert _is_overflow(ContextOverflowError("x"))
    assert _is_overflow(RuntimeError("Error code: 400 - context limit exceeded"))
    try:
        try:
            raise ValueError("The input token count (1200000) exceeds the maximum number of tokens allowed (1048576).")
        except ValueError as inner:
            raise RuntimeError("model call failed") from inner
    except RuntimeError as exc:
        assert _is_overflow(exc)
    assert not _is_overflow(RuntimeError("Rate limit reached: tokens per min (TPM): context length"))
    assert not _is_overflow(RuntimeError("bad request"))


def test_pictures_attached_to_earlier_messages_are_dropped() -> None:
    old = HumanMessage(content=[{"type": "text", "text": "see"}, IMAGE], id="h1")
    new = HumanMessage(content=[{"type": "text", "text": "and this"}, IMAGE], id="h2")
    updates = economy.diet([old, AIMessage(content="ok", id="a"), new])
    assert [u.id for u in updates] == ["h1"]
    assert not any(economy._is_media(b) for b in updates[0].content)


def test_tokens_are_counted_conservatively() -> None:
    text = "0123456789abcdef" * 3000
    assert economy.count_tokens([HumanMessage(text)]) >= len(text) // 3


def test_the_summarization_trigger_follows_the_window(monkeypatch) -> None:
    class Model:
        profile = {"max_input_tokens": 32_000}

    assert economy.summarize_above(Model()) == int(32_000 * economy.SUMMARIZE_SHARE)
    monkeypatch.setenv("TRADERA_DEFAULT_CONTEXT_WINDOW", "16000")
    assert economy.summarize_above(object()) == int(16_000 * economy.SUMMARIZE_SHARE)


def test_memory_notes_are_capped() -> None:
    mw = memory.OpenVikingMemory({memory.SPACE_NOTES: "note\n" * 10_000})
    assert mw.name == "MemoryMiddleware"
    assert len(mw.block) < memory.NOTES_MAX_CHARS + 3_000
    assert "condense it with rewrite_notes" in mw.block


async def test_attached_text_has_a_budget(platform, tmp_path: Path) -> None:
    r, model = runner(platform, tmp_path, [AIMessage(content="read")])
    req = turn_request(LEAD, "files", token="tok-lead", role="lead", message_id="m0")
    req["turn"]["attachments"] = [{"id": f"f{i}", "name": f"f{i}.txt", "mime": "text/plain", "content": "y" * 30_000}
                                  for i in range(5)]
    out = await r.prompt(req)
    assert out.status == "done"
    first = next(m for m in model.seen[0] if isinstance(m, HumanMessage))
    assert len(str(first.content)) < 70_000
    assert "read it with read_attachment" in str(first.content)
    assert not [m for m in model.seen[0] if isinstance(m, ToolMessage)]


def test_the_same_call_long_after_is_noticed() -> None:
    def calls(*named: tuple[str, dict]) -> list[AIMessage]:
        return [AIMessage(content="", tool_calls=[{"name": n, "args": a, "id": f"x{i}"}]) for i, (n, a) in enumerate(named)]

    work = [("execute", {"command": f"echo {i}"}) for i in range(12)]
    late = calls(("execute", {"command": "cat big.txt"}), *work[:7], ("execute", {"command": "cat big.txt"}),
                 *work[7:], ("execute", {"command": "cat big.txt"}))
    found = guard.notes([HumanMessage("go"), *late], 20, 100)
    assert any("execute" in n and "this turn" in n for n in found)
    # Paging through a skill is reading it, not repeating a call.
    pages = calls(*[("read_file", {"file_path": "/w/skills/x/SKILL.md", "offset": o}) for o in (0, 100, 200)])
    assert guard.notes([HumanMessage("go"), *pages], 3, 100) == []


def test_the_guard_counts_the_calls_it_warned_of_a_loop() -> None:
    class Request:
        def __init__(self, messages):
            self.messages = messages

        def override(self, messages, **_):
            return Request(messages)

    same = [AIMessage(content="", tool_calls=[{"name": "app__help", "args": {}, "id": f"h{i}"}]) for i in range(3)]
    g = guard.TurnGuard(budget=100)
    g._request(Request([HumanMessage("go")]))
    assert g.loops == 0
    g._request(Request([HumanMessage("go"), *same]))
    assert g.loops == 1


SPEC = "\n# Canvas Composer DSL Specification\n\n" + "\n".join(f"Rule {i}: shapes are SVG elements." for i in range(600))


def miro(platform) -> None:
    platform.apps = [{"name": "Tool Miro", "kind": "tool", "bot_id": "bot-miro", "description": "Miro boards.",
                      "commands": [{"name": "canvas_get_canvas_composer_skill", "description": "The DSL to draw with.",
                                    "schema": {"type": "object", "properties": {"miro_url": {"type": "string"},
                                                                                "step": {"type": "string"}}}}]}]
    text = json.dumps({"skill": SPEC})
    platform.app_reply = json.dumps({"content": [{"type": "text", "text": text}]})


async def test_an_apps_instructions_stay_whole_in_the_conversation(platform, tmp_path: Path) -> None:
    miro(platform)
    name, args = "tool_miro__canvas_get_canvas_composer_skill", {"step": "dsl"}
    r, model = runner(platform, tmp_path, [call(name, args, cid="m0"), AIMessage(content="drawn")])
    out = await r.prompt(turn_request(LEAD, "draw on the board", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    # The agent has the whole skill to work from, as text: not a preview of a file, not one line of JSON.
    first = next(m for m in model.seen[1] if isinstance(m, ToolMessage))
    assert str(first.content) == SPEC


async def test_instructions_too_large_to_keep_go_to_a_file(platform, tmp_path: Path) -> None:
    miro(platform)
    # Past PIN_MAX_CHARS but well inside what the model's window could hold: it
    # must still go to a file, or a real spec this size floods the context.
    huge = "# Spec\n" + "\n".join(f"Rule {i}: " + "x" * 15 for i in range(2000))
    platform.app_reply = json.dumps({"content": [{"type": "text", "text": json.dumps({"skill": huge})}]})
    name, args = "tool_miro__canvas_get_canvas_composer_skill", {"step": "dsl"}
    r, model = runner(platform, tmp_path, [call(name, args, cid="m0"), AIMessage(content="done")])
    out = await r.prompt(turn_request(LEAD, "draw", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    results = [m for m in model.seen[-1] if isinstance(m, ToolMessage)]
    assert "large_tool_results" in str(results[0].content)


async def test_every_call_the_agent_makes_runs(platform, tmp_path: Path) -> None:
    # The guard advises; it never refuses a call (repeats included).
    miro(platform)
    platform.app_reply = '{"content": [{"type": "text", "text": "three stickies"}]}'
    same = {"name": "tool_miro__canvas_get_canvas_composer_skill", "args": {"step": "items"}, "type": "tool_call"}
    step = AIMessage(content="", tool_calls=[{**same, "id": f"p{i}"} for i in range(3)])
    r, model = runner(platform, tmp_path, [step, AIMessage(content="done")])
    out = await r.prompt(turn_request(LEAD, "list", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    assert len([run for run in platform.tool_runs if run.get("bot") == "bot-miro"]) == 3


def test_skills_and_specs_are_instructions() -> None:
    assert economy.reference({"name": "tool_miro__canvas_get_canvas_composer_skill", "args": {}})
    assert economy.reference({"name": "api__get_spec", "args": {}})
    assert economy.reference({"name": "app__help", "args": {}})
    assert not economy.reference({"name": "skills__create_skill", "args": {}})
    assert not economy.reference({"name": "docs__create_doc", "args": {}})
    assert economy.reference({"name": "read_file", "args": {"file_path": "/w/.tradera/skills/shared/a/SKILL.md"}})
    assert not economy.reference({"name": "read_file", "args": {"file_path": "/w/main.py"}})
