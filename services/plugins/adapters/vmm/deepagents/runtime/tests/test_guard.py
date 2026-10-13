from __future__ import annotations

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


def test_the_recursion_limit_is_above_the_budget() -> None:
    class Graph:
        def get_graph(self):
            class G:
                nodes = ["__start__", "model", "tools", "A.before_model", "B.after_model", "C.before_agent", "__end__"]
            return G()

    assert guard.recursion_limit(Graph(), 100) >= 4 * 100


def test_repeats_and_polling_are_noticed() -> None:
    same = [AIMessage(content="", tool_calls=[{"name": "execute", "args": {"command": "ls"}, "id": f"c{i}"}])
            for i in range(3)]
    found = guard.notes([HumanMessage("go"), *same], 3, 100)
    assert any("execute" in n and "same arguments" in n for n in found)
    polls = [AIMessage(content="", tool_calls=[{"name": "check_tasks", "args": {"task_ids": [str(i)]}, "id": f"p{i}"}])
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
