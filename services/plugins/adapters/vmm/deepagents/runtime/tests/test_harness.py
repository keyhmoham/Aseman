"""Agents improving their harness with harness2: the cycle (propose INV and DOM,
compose, probe on real turns, adopt or drop, reflect into the experience
library), and a harness at work in OpenCode (skills, subagents, always-on
text), with a real OpenCode editor session on the node's learn endpoint."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import pytest
import pytest_asyncio
from langgraph.checkpoint.memory import InMemorySaver

from tradera_agents.agent import Outcome, Runner
from tradera_agents.harness import Harness, Settings, View
from tradera_agents.harness.editor import Editor
from tradera_agents.store import Store
from fakes import CODER, LEAD, Platform, say, turn_request, use
from ochost import host, opencode_binary, system_of, tool_names, tool_results

harness2 = pytest.importorskip("harness2")
from harness2.core import tree as h2tree  # noqa: E402
from harness2.substrate.opencode import OPENCODE_SURFACE  # noqa: E402

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])
SKILL = "---\nname: release-notes\ndescription: writing release notes from a changelog\n---\n\nGroup changes by user impact.\n"


class FakeEditor:
    """harness2's stages, as a scripted editor writes them into context/harness."""

    def __init__(self) -> None:
        self.missions: dict[str, str] = {}

    async def session(self, work: Path, mission: str, *, space: str, agent_vm: str, label: str) -> str:
        stage = label.split()[-1]
        self.missions[stage] = mission
        harness = work / "context" / "harness"
        assert (work / "context" / "rollouts").is_dir() and (work / "context" / "task.md").is_file()
        if stage == "INV":
            (harness / "skills" / "release-notes").mkdir(parents=True)
            (harness / "skills" / "release-notes" / "SKILL.md").write_text(SKILL)
            return "<notes>\n- added the release-notes skill: turn-1 hand-rolled the notes and missed a section\n</notes>"
        if stage == "DOM":
            (harness / "guardrails.md").write_text("- Every release note names the version it covers.\n")
            return "<notes>\n- guardrail: turn-1 left the version out\n</notes>"
        if stage == "compose":
            for label_ in ("inv", "dom"):
                shutil.copytree(work / "context" / "pool" / label_ / "harness", harness, dirs_exist_ok=True)
            return "<notes>\nkept -> both edits -> turn-1 omitted the version and a section\n</notes>"
        if stage == "reflect":
            return ("<edits>\ncomponent: skills/release-notes\ncandidates: inv\nchange: a release-notes procedure\n"
                    "observed: probed turns covered every section\nverdict: helped\n</edits>\n<experience>\n"
                    "cue: a recurring document type with a fixed anatomy\nlesson: put its anatomy in a skill named in "
                    "guardrails.md\nevidence: turn-1 vs the probed turns\nconfidence: medium, two probed turns\n"
                    "</experience>")
        raise AssertionError(stage)


def delivered(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
    """The decision model: an answer delivers unless it is empty."""
    return {k: {"probability": 0.9 if state.get("answer", "").strip() else 0.1} for k in questions}


def ctx_for(platform: Platform, tmp_path: Path, agent: dict[str, Any] = CODER, *, judge: bool = True,
            **extra: Any) -> Any:
    from tradera_agents.decision import DecisionClient

    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), gateway_factory=platform.gateway)
    ctx = r._context(turn_request(agent, "write the release notes", token="tok-coder", **extra))
    if judge:
        platform.decide = platform.decide or delivered
        ctx.decision = DecisionClient(ctx.gateway, "jev")
    return ctx


def a_run(calls: int = 3, failed_tools: int = 0) -> Any:
    tools = [{"type": "tool", "tool": "execute", "state": {"status": "error" if i < failed_tools else "completed",
                                                            "input": {"command": "ls"}, "output": "x"}}
             for i in range(3)]
    return SimpleNamespace(guard=SimpleNamespace(calls=calls, budget=10), delivered=[],
                           trajectory=[{"type": "text", "text": "thinking"}, *tools])


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    return p


async def test_a_poor_turn_starts_a_cycle_whose_harness_is_probed_adopted_and_learned_from(platform: Platform, tmp_path: Path) -> None:
    editor = FakeEditor()
    h = Harness(tmp_path / "harness", editor, Settings(every=50, cooldown=0, probe_turns=2))
    ctx = ctx_for(platform, tmp_path)
    view = await h.view(ctx)
    assert view is not None and view.arm == "champion" and view.tree == {} and view.always_on == ""
    # A failed turn: a cycle runs in the background.
    await h.observe(ctx, a_run(failed_tools=3), Outcome(reply="", status="failed"), view)
    await h.drain()
    assert "YOUR DIMENSION: INV" in editor.missions["INV"] and "YOUR DIMENSION: DOM" in editor.missions["DOM"]
    assert "composing THE final harness" in editor.missions["compose"]
    assert "write the release notes" not in editor.missions["INV"]  # the evidence is on disk, not in the mission
    ah = view.agent
    assert ah.state().probe is not None
    # The composed harness works the next turns: always-on text, the skill and its trigger.
    probe_view = await h.view(ctx)
    assert probe_view.arm == "challenger"
    assert "release-notes" in probe_view.files.skills
    assert "names the version it covers" in probe_view.always_on
    assert "load the `release-notes` skill" in probe_view.always_on  # harness2's autotrigger
    for _ in range(2):
        await h.observe(ctx, a_run(), Outcome(reply="Release notes for v2: …"), probe_view)
    await h.drain()
    # Adopted: it is the agent's harness now, and the lesson is in its library.
    assert ah.state().probe is None and ah.state().adopted == 1
    adopted = h2tree.read_tree(OPENCODE_SURFACE, ah.champion)
    assert "skills/release-notes/SKILL.md" in adopted
    assert "verdict: helped" in editor.missions["reflect"] or "experience" in editor.missions["reflect"].lower()
    index = (ah.library / "INDEX.md").read_text()
    entry = next((ah.library / "harnesses").iterdir())
    experience = (entry / "EXPERIENCE.md").read_text()
    assert "a recurring document type" in experience and "adopted" in experience
    assert entry.name in index
    assert (await h.view(ctx)).arm == "champion"


async def test_a_probed_harness_that_does_worse_is_dropped(platform: Platform, tmp_path: Path) -> None:
    h = Harness(tmp_path / "harness", FakeEditor(), Settings(every=3, cooldown=0, probe_turns=1))
    ctx = ctx_for(platform, tmp_path)
    view = await h.view(ctx)
    for _ in range(3):  # good turns, then a cycle is due
        await h.observe(ctx, a_run(calls=1), Outcome(reply="fine"), view)
    await h.drain()
    probe_view = await h.view(ctx)
    assert probe_view.arm == "challenger"
    await h.observe(ctx, a_run(failed_tools=3), Outcome(reply="", status="failed"), probe_view)
    await h.drain()
    ah = view.agent
    assert not ah.challenger.exists() and h2tree.read_tree(OPENCODE_SURFACE, ah.champion) == {}
    entry = next((ah.library / "harnesses").iterdir())
    assert "dropped" in (entry / "EXPERIENCE.md").read_text()


async def test_no_cycle_without_a_decision_model_to_judge_it(platform: Platform, tmp_path: Path) -> None:
    editor = FakeEditor()
    h = Harness(tmp_path / "harness", editor, Settings(every=1, cooldown=0, probe_turns=1))
    ctx = ctx_for(platform, tmp_path, judge=False)
    view = await h.view(ctx)
    await h.observe(ctx, a_run(failed_tools=3), Outcome(reply="", status="failed"), view)
    await h.drain()
    assert not editor.missions and view.agent.state().probe is None
    assert view.agent.turns(1)[0]["status"] == "failed"  # still recorded


async def test_a_probe_without_judged_turns_is_not_adopted(platform: Platform, tmp_path: Path) -> None:
    h = Harness(tmp_path / "harness", FakeEditor(), Settings(every=50, cooldown=0, probe_turns=2))
    ctx = ctx_for(platform, tmp_path)
    view = await h.view(ctx)
    await h.observe(ctx, a_run(failed_tools=3), Outcome(reply="", status="failed"), view)
    await h.drain()
    ctx.decision = None  # the decision model went off: the probed turns go unjudged
    probe_view = await h.view(ctx)
    for _ in range(2):
        await h.observe(ctx, a_run(), Outcome(reply="Release notes for v2"), probe_view)
    await h.drain()
    ah = view.agent
    assert ah.state().adopted == 0 and not ah.challenger.exists()
    entry = next((ah.library / "harnesses").iterdir())
    assert "not proven" in (entry / "EXPERIENCE.md").read_text()


async def test_no_harness_for_requests_without_memory_or_when_off(platform: Platform, tmp_path: Path) -> None:
    h = Harness(tmp_path / "harness", FakeEditor(), Settings())
    req_ctx = ctx_for(platform, tmp_path)
    req_ctx.turn.no_memory = True
    assert await h.view(req_ctx) is None
    off = Harness(tmp_path / "harness", FakeEditor(), Settings(enabled=False))
    assert await off.view(ctx_for(platform, tmp_path)) is None


async def test_harnesses_are_kept_per_space(platform: Platform, tmp_path: Path) -> None:
    h = Harness(tmp_path / "harness", FakeEditor(), Settings())
    one = ctx_for(platform, tmp_path)
    other = ctx_for(platform, tmp_path)
    other.turn.space_id = "space-2"
    assert h.agent(one).dir != h.agent(other).dir


# --- in OpenCode ---------------------------------------------------------------------

needs_opencode = pytest.mark.skipif(not opencode_binary(), reason="needs the opencode binary")


@pytest_asyncio.fixture(loop_scope="module", scope="module")
async def engine(tmp_path_factory: pytest.TempPathFactory) -> Any:
    if not opencode_binary():
        pytest.skip("needs the opencode binary")
    async for e in host(tmp_path_factory.mktemp("opencode-harness")):
        yield e


def real_harness(engine: Any, platform: Platform, root: Path) -> Harness:
    client = httpx.AsyncClient(transport=httpx.MockTransport(platform.handle))
    editor = Editor(engine, root, node_url="http://node", secret="test-secret", client=client)
    return Harness(root, editor, Settings(every=50, cooldown=0, probe_turns=1))


@needs_opencode
@pytest.mark.asyncio(loop_scope="module")
async def test_an_agent_works_with_its_harness_in_opencode(platform: Platform, tmp_path: Path, engine: Any) -> None:
    h = real_harness(engine, platform, tmp_path / "harness")
    engine.harness = h
    try:
        ctx = ctx_for(platform, tmp_path)
        champion = h.agent(ctx).champion
        h2tree.write_tree(OPENCODE_SURFACE, {
            "guardrails.md": "- When writing release notes, load the `release-notes` skill.\n",
            "skills/release-notes/SKILL.md": SKILL,
            "sub_agents/changelog-reader/AGENT.md": "---\nmode: subagent\ndescription: reads a long changelog and "
                                                    "returns the user-facing changes\n---\n\nYou read changelogs.\n",
            "scripts/count_lines.py": "import sys\nprint(len(open(sys.argv[1]).read().splitlines()))\n",
        }, champion, stubs=False)

        def model(req: dict[str, Any]) -> dict[str, Any]:
            system = system_of(req)
            if system.startswith("You read changelogs."):
                return say("users can now export to csv")
            results = tool_results([req])
            if "skill" not in results:
                return use("skill", {"name": "release-notes"})
            if "subagent" not in results:
                return use("subagent", {"description": "read changelog", "prompt": "Read CHANGELOG.md",
                                        "subagent_type": "changelog-reader"})
            return say("notes written")

        platform.llm = [model] * 10
        r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), gateway_factory=platform.gateway, engine=engine)
        out = await r.prompt(turn_request(CODER, "write the release notes", token="tok-coder"))
        assert out.status == "done" and out.reply == "notes written", out
        first = platform.llm_requests[0]
        assert {"skill", "subagent"} <= set(tool_names(first))
        assert "## Your harness" in system_of(first) and "load the `release-notes` skill" in system_of(first)
        assert ".tradera/agents/coder/harness" in system_of(first)
        assert (WORKSPACE / ".tradera/agents/coder/harness/scripts/count_lines.py").is_file()
        results = tool_results(platform.llm_requests)
        assert "Group changes by user impact." in results["skill"]
        assert "users can now export to csv" in results["subagent"]
        # The subagent kept its own prompt (OpenCode's environment block removed).
        sub = next(q for q in platform.llm_requests if system_of(q).startswith("You read changelogs."))
        assert "Working directory" not in system_of(sub) and "You are coder" not in system_of(sub)
        # The turn was recorded for the agent's next improvement.
        assert h.agent(ctx).turns(1)[0]["answer"] == "notes written"
    finally:
        engine.harness = None


@needs_opencode
@pytest.mark.asyncio(loop_scope="module")
async def test_harness2_stages_run_as_opencode_sessions_on_the_learn_endpoint(platform: Platform, tmp_path: Path, engine: Any) -> None:
    h = real_harness(engine, platform, tmp_path / "harness")
    ctx = ctx_for(platform, tmp_path)
    ah = h.agent(ctx)
    ah.record_turn({"request": "write the release notes", "answer": "", "status": "failed", "arm": "champion",
                    "quality": 0.0, "steps": 9, "budget": 10, "trajectory": "[ACTION] execute(...)"})

    def editor_model(req: dict[str, Any]) -> dict[str, Any]:
        system = system_of(req)
        done = "write" in tool_results([req])
        if "YOUR DIMENSION: INV" in system and not done:
            return use("write", {"filePath": "context/harness/guardrails.md",
                                 "content": "- Check the version before you answer.\n"})
        if "YOUR DIMENSION: DOM" in system and not done:
            return use("write", {"filePath": "context/harness/LongTermMEMORY.md",
                                 "content": "Release notes here group changes by user impact.\n"})
        if "composing THE final harness" in system and not done:
            return use("write", {"filePath": "context/harness/guardrails.md",
                                 "content": "- Check the version before you answer.\n"})
        return say("<notes>\n- from turn-1\n</notes>")

    platform.learn = [editor_model] * 12
    state = ah.state()
    await h._cycle(ah, __import__("tradera_agents.harness", fromlist=["bench_prompts"]).bench_prompts(ctx),
                   ctx.space, ctx.agent.vm_id)
    challenger = h2tree.read_tree(OPENCODE_SURFACE, ah.challenger)
    assert challenger.get("guardrails.md", "").startswith("- Check the version")
    assert ah.state().probe is not None and state.probe is None
    # Every model call of the editor went to the learn endpoint, for this agent and space.
    assert platform.learn_requests and all(q["agent"] == CODER["vm_id"] and q["space"] == "space-1"
                                           for q in platform.learn_requests)
    assert not any(n.startswith("tradera_") for q in platform.learn_requests for n in tool_names(q))
    assert {"read", "write"} <= set(tool_names(platform.learn_requests[0]))
    assert "bash" not in tool_names(platform.learn_requests[0])


async def test_view_type() -> None:
    assert View(arm="champion", tree={}).files.skills == {}


@needs_opencode
@pytest.mark.asyncio(loop_scope="module")
async def test_a_failed_turn_on_opencode_starts_an_improvement_cycle(platform: Platform, tmp_path: Path, engine: Any) -> None:
    h = Harness(tmp_path / "harness", FakeEditor(), Settings(every=50, cooldown=0, probe_turns=1))
    engine.harness = h
    try:
        platform.llm_status = 400
        platform.decide = delivered
        r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), gateway_factory=platform.gateway, engine=engine)
        req = turn_request(CODER, "write the release notes", token="tok-coder")
        req["decision"] = {"enabled": True, "model": "jev"}
        out = await r.prompt(req)
        assert out.status == "failed"
        await h.drain()
        ah = h.agent(ctx_for(platform, tmp_path))
        assert ah.state().probe is not None and ah.challenger.is_dir()
        assert ah.turns(1)[0]["status"] == "failed"
        # The next turn works with the probed harness.
        platform.llm_status = 200
        platform.llm = [say("v2 notes")]
        req = turn_request(CODER, "again", token="tok-coder")
        req["decision"] = {"enabled": True, "model": "jev"}
        out = await r.prompt(req)
        assert out.reply == "v2 notes"
        assert "load the `release-notes` skill" in system_of(platform.llm_requests[-1])
        await h.drain()
        assert ah.state().adopted == 1
    finally:
        engine.harness = None
