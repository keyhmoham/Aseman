from __future__ import annotations

import json
import re
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
    steps = [call("execute", {"command": f"python3 -c \"print('x' * 12000, {i})\""}, cid=f"e{i}") for i in range(12)]
    r, model = runner(platform, tmp_path, [*steps, AIMessage(content="done")])
    out = await r.prompt(turn_request(LEAD, "run them", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    last = [m for m in model.seen[-1] if isinstance(m, ToolMessage)]
    # Every result is still there exactly once; the old ones are short now.
    assert len(last) == 12
    assert sum(len(str(m.content)) for m in last[:4]) < 4 * 1200
    assert all(len(str(m.content)) > 10000 for m in last[-8:])


def ran(i: int, name: str, args: dict, content: str) -> list:
    return [AIMessage(content="", id=f"a{i}", tool_calls=[{"name": name, "args": args, "id": f"c{i}"}]),
            result(i, content, name)]


def test_instructions_the_agent_read_stay_whole() -> None:
    big = "line of output\n" * 2000
    guide = "How to use the board: " + "rule. " * 2000
    messages = [HumanMessage("go", id="h"), *ran(0, "board__get_instructions", {}, guide),
                *ran(1, "read_file", {"file_path": "/w/.tradera/skills/shared/a/SKILL.md"}, guide),
                *ran(2, "read_file", {"file_path": "/large_tool_results/c3", "offset": 0}, big),
                *ran(3, "execute", {"command": "ls"}, big),
                *[m for i in range(4, 14) for m in ran(i, "execute", {"command": f"echo {i}"}, big)]]
    # c2 reads what a work tool's large result left in a file: that is trimmed as usual.
    after = apply(messages, economy.diet(messages))
    results = {m.tool_call_id: m for m in after if isinstance(m, ToolMessage)}
    assert results["c0"].content == guide and results["c1"].content == guide
    assert "trimmed from context" in results["c2"].content and "trimmed from context" in results["c3"].content
    # Read again, only the newest copy stays whole.
    again = [*after, *ran(20, "board__get_instructions", {}, guide)]
    results = {m.tool_call_id: m for m in apply(again, economy.diet(again)) if isinstance(m, ToolMessage)}
    assert "trimmed from context" in results["c0"].content and results["c20"].content == guide


def test_what_the_agent_reads_of_large_instructions_stays_whole() -> None:
    big = "line of output\n" * 2000
    messages = [HumanMessage("go", id="h"), *ran(0, "app__help", {}, "saved to /large_tool_results/c0"),
                *ran(1, "read_file", {"file_path": "/large_tool_results/c0", "offset": 0}, "rule. " * 2000),
                *[m for i in range(2, 12) for m in ran(i, "execute", {"command": f"echo {i}"}, big)]]
    results = {m.tool_call_id: m for m in apply(messages, economy.diet(messages)) if isinstance(m, ToolMessage)}
    assert results["c1"].content == "rule. " * 2000


def test_a_large_window_keeps_more(monkeypatch) -> None:
    class Model:
        profile = {"max_input_tokens": 200_000}

    above = economy.summarize_above(Model())
    assert above == 120_000
    assert economy.trim_above(above) == 60_000 and economy.summary_keeps(above) == 30_000
    # Small windows keep their old, smaller sizes.
    assert economy.trim_above(19_200) == 9_600 and economy.summary_keeps(19_200) == 6_400
    # An operator can bound what a call costs.
    monkeypatch.setenv("TRADERA_SUMMARIZE_MAX_TOKENS", "48000")
    assert economy.summarize_above(Model()) == 48_000


def test_long_lines_are_broken_to_fit_pages() -> None:
    assert economy.reflow("short\nlines") == "short\nlines"
    # JSON is indented first: nothing is lost.
    data = {"items": [{"id": i, "name": f"item {i}"} for i in range(300)]}
    out = economy.reflow(json.dumps(data))
    assert json.loads(out) == data and max(map(len, out.splitlines())) <= economy.LINE_MAX
    # Anything else is broken at spaces, or cut where there are none.
    words = economy.reflow("word " * 3000)
    assert words.startswith("[Lines longer") and max(map(len, words.splitlines())) <= economy.LINE_MAX
    assert "".join(words.splitlines()[1:]).replace(" ", "") == "word" * 3000
    assert max(map(len, economy.reflow("x" * 9000).splitlines())) <= economy.LINE_MAX


async def test_a_large_one_line_result_can_be_paged_through(platform, tmp_path: Path) -> None:
    def page(offset):
        def step(messages):
            saved = next(m for m in messages if isinstance(m, ToolMessage) and m.tool_call_id == "e0")
            path = re.search(r"at this path: (\S+)", str(saved.content)).group(1)
            return call("read_file", {"file_path": path, "offset": offset, "limit": 500}, cid=f"r{offset}")
        return step

    r, model = runner(platform, tmp_path, [
        call("execute", {"command": "python3 -c \"print('word ' * 16000)\""}, cid="e0"),
        page(0), page(20), AIMessage(content="done"),
    ])
    out = await r.prompt(turn_request(LEAD, "run it", token="tok-lead", role="lead", message_id="m0"))
    assert out.status == "done", out
    results = {m.tool_call_id: str(m.content) for m in model.seen[-1] if isinstance(m, ToolMessage)}
    assert "large_tool_results" in results["e0"]
    # Each page shows whole lines and says where the next one starts; the second goes on from there.
    assert "truncated mid-line" not in results["r0"] and "next offset" in results["r0"]
    assert results["r20"].count("word") > 100
