from __future__ import annotations

from pathlib import Path

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from tradera_agents import economy
from fakes import LEAD, call, turn_request
from test_runtime import platform, runner  # noqa: F401

IMAGE = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}


def result(i: int, content, name: str = "execute") -> ToolMessage:
    return ToolMessage(content=content, tool_call_id=f"c{i}", name=name, id=f"t{i}")


def apply(messages: list, updates: list) -> list:
    by_id = {u.id: u for u in updates}
    return [by_id.get(m.id, m) for m in messages]


def test_old_screenshots_are_dropped_and_the_newest_kept() -> None:
    messages = [HumanMessage("look", id="h"), *[result(i, [{"type": "text", "text": f"shot {i}"}, IMAGE], "read_file") for i in range(4)]]
    after = apply(messages, economy.diet(messages))
    seen = [any(economy._is_media(b) for b in m.content) for m in after[1:]]
    assert seen == [False, False, True, True]
    assert "shot 0" in economy._text_of(after[1].content) and "removed from context" in economy._text_of(after[1].content)


def test_old_tool_output_is_trimmed_once_the_conversation_is_large() -> None:
    big = "line of output\n" * 2000
    messages = [HumanMessage("go", id="h"), *[result(i, big) for i in range(10)], result(10, big, "task")]
    small = [HumanMessage("go", id="h"), result(0, "short")]
    assert economy.diet(small) == []
    after = apply(messages, economy.diet(messages))
    trimmed = ["trimmed from context" in m.content for m in after[1:]]
    # The newest results stay whole, and so does an agent's answer.
    assert trimmed == [True] * 3 + [False] * 8
    assert after[1].content.startswith("line of output")
    # A second pass changes nothing that was already trimmed: the prefix is stable.
    again = economy.diet(after)
    assert not [u for u in again if u.id in {m.id for m in after[1:4]}]


async def test_a_long_turn_keeps_its_context_small(platform, tmp_path: Path) -> None:
    steps = [call("execute", {"command": "python3 -c \"print('x' * 12000)\""}, cid=f"e{i}") for i in range(12)]
    r, model = runner(platform, tmp_path, [*steps, AIMessage(content="done")])
    out = await r.prompt(turn_request(LEAD, "run them", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    last = [m for m in model.seen[-1] if isinstance(m, ToolMessage)]
    # Every result is still there exactly once; the old ones are short now.
    assert len(last) == 12
    assert sum(len(str(m.content)) for m in last[:4]) < 4 * 1200
    assert all(len(str(m.content)) > 10000 for m in last[-8:])
