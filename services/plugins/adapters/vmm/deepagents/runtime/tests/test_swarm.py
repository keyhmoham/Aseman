"""The swarm: hybrid team setup (space, marketplace, generated) with the
language model and the decision model, plans with the dependencies that are
not needed dropped, and tasks run in parallel — several for the same agent
as parallel instances of it."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import pytest
from langchain_core.messages import AIMessage
from langgraph.checkpoint.memory import InMemorySaver

from aseman_agents.agent import Runner
from aseman_agents.decision import DecisionClient
from aseman_agents.store import Store
from aseman_agents.swarm import planner, team_setup
from aseman_agents.swarm.tools import swarm_tools
from fakes import CODER, LEAD, Platform, ScriptedModel, call, listing, turn_request


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    p.catalog = [
        listing(1, "Data Analyst", "Cleans data, runs statistics and builds charts and dashboards.",
                ["Sales analysis", "Dashboards"]),
        listing(2, "Designer", "Designs interfaces, illustrations and brand visuals.", ["Logos", "UI mockups"]),
        listing(3, "Illustrator", "Draws illustrations and visuals for books.", ["Book covers"]),
    ]
    return p


def context(platform: Platform, tmp_path: Path, script: list[Any], *, decision: bool = True) -> tuple[Any, Store]:
    model = ScriptedModel(script=script)
    store = Store(str(tmp_path / "rt.db"))
    r = Runner(store, InMemorySaver(), model_factory=lambda a, g: model, gateway_factory=platform.gateway)
    ctx = r._context(turn_request(LEAD, "build it", token="tok-lead", role="lead"))
    ctx.llm = model
    ctx.decision = DecisionClient(ctx.gateway, "jev") if decision else None
    return ctx, store


def js(value: Any) -> AIMessage:
    return AIMessage(content="```json\n" + json.dumps(value) + "\n```")


ROLES = {"roles": [
    {"key": "research", "title": "Market researcher", "needs": "research the market the dashboard serves", "instances": 2},
    # Programming is OpenCode's: a development role is never staffed.
    {"key": "engineer", "title": "Software engineer", "needs": "write and test the code", "instances": 2},
    {"key": "analyst", "title": "Data analyst", "needs": "analyse sales data and build dashboards"},
    {"key": "visuals", "title": "Visual designer", "needs": "design illustrations and visuals"},
    {"key": "legal", "title": "Contract lawyer", "needs": "review the supplier contract"},
]}


def decide_team(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
    out = {}
    for qid, q in questions.items():
        text = q["instructions"]
        p = 0.05
        if "`coder`" in text and "Market researcher" in text:
            p = 0.92
        elif "`Data Analyst`" in text and "Data analyst" in text:
            p = 0.88
        elif "Visual designer" in text and ("`Designer`" in text or "`Illustrator`" in text):
            p = 0.6 if "`Designer`" in text else 0.55  # a close call: the language model settles it
        elif qid.startswith("s"):  # a written specialist fits its role
            p = 0.9
        out[qid] = {"probability": p}
    return out


async def test_a_team_reuses_the_space_and_the_market_and_writes_only_what_is_missing(platform: Platform, tmp_path: Path) -> None:
    platform.decide = decide_team
    ctx, store = context(platform, tmp_path, [
        js(ROLES),
        js({"choices": {"visuals": "designer"}}),
        js({"agents": [{"role": "legal", "name": "contract-lawyer", "description": "Reviews contracts.",
                        "instructions": "Read every clause; flag risks with the clause number.",
                        "skills": [{"name": "redline", "description": "Redlining", "instructions": "Mark changes."}]}]}),
    ])
    [assemble, _] = swarm_tools(ctx, store)
    text = await assemble.ainvoke({"goal": "Ship the sales dashboard app with visuals, after the contract review"})
    team = store.team(ctx.base_thread)
    by_role = {r["role"]: r for r in team["roles"]}
    # Reused from the space, picked by the decision model alone.
    assert by_role["research"]["agent"] == "coder" and by_role["research"]["source"] == "space"
    assert by_role["research"]["how"] == "decision model" and by_role["research"]["instances"] == 2
    # No agent is staffed for programming.
    assert "engineer" not in by_role
    # Hired from the marketplace.
    assert by_role["analyst"]["agent"] == "Data Analyst" and by_role["analyst"]["source"] == "hired"
    # A close call settled by the language model.
    assert by_role["visuals"]["agent"] == "Designer" and by_role["visuals"]["how"] == "language model"
    # Nobody fits: written and recruited.
    assert by_role["legal"]["how"] == "generated" and by_role["legal"]["agent"].startswith("contract-lawyer")
    assert sorted(platform.hired) == ["lst-1", "lst-2"]
    recruit = next(body for name, body in platform.calls if name == "spaces.agent_recruit")
    assert recruit["skills"][0]["name"] == "redline"
    assert "hired from the marketplace" in text and "already in the space" in text and "new specialist" in text
    assert any(e.get("text", "").startswith("Team\n") for e in platform.logs)
    # One decision request scored every shortlisted pair at once.
    team_scoring = [d for d in platform.decisions if any(k.startswith("r") for k in d["questions"])]
    assert len(team_scoring) == 1


def test_development_roles_are_opencodes() -> None:
    for title in ("Software engineer", "Frontend developer", "Full-stack dev", "Backend", "DevOps"):
        assert team_setup.development_role(title), title
    assert team_setup.development_role("Engineer", "write and test the code")
    for title in ("Data analyst", "Market researcher", "Visual designer", "Contract lawyer", "Copywriter",
                  "Mechanical engineer", "Product development manager"):
        assert not team_setup.development_role(title, "review the requirements"), title


async def test_without_a_decision_model_the_language_model_picks(platform: Platform, tmp_path: Path) -> None:
    ctx, store = context(platform, tmp_path, [
        js({"roles": [{"key": "analyst", "title": "Data analyst", "needs": "dashboards"}]}),
        js({"choices": {"analyst": "data-analyst"}}),
    ], decision=False)
    team = await team_setup.assemble(ctx, "a dashboard")
    assert team.picks[0].member.name == "Data Analyst" and team.picks[0].how == "language model"
    assert not platform.decisions


async def test_a_spec_that_does_not_fit_is_rewritten(platform: Platform, tmp_path: Path) -> None:
    calls = {"n": 0}

    def decide(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
        out = {}
        for qid in questions:
            if qid.startswith("s"):
                calls["n"] += 1
                out[qid] = {"probability": 0.2}
            else:
                out[qid] = {"probability": 0.01}
        return out

    platform.decide = decide
    ctx, store = context(platform, tmp_path, [
        js({"roles": [{"key": "legal", "title": "Contract lawyer", "needs": "review contracts"}]}),
        js({"agents": [{"role": "legal", "name": "helper", "description": "helps", "instructions": "Help."}]}),
        js({"agents": [{"role": "legal", "name": "contract-lawyer", "description": "Reviews contracts.",
                        "instructions": "Read every clause."}]}),
    ])
    team = await team_setup.assemble(ctx, "review the contract")
    assert calls["n"] == 1
    assert team.picks[0].member.name.startswith("contract-lawyer")


async def test_the_decision_model_drops_dependencies_that_are_not_needed(platform: Platform, tmp_path: Path) -> None:
    def decide(state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
        return {qid: {"probability": 0.9 if "uses the summary" in q["instructions"] else 0.05}
                for qid, q in questions.items()}

    platform.decide = decide
    ctx, _ = context(platform, tmp_path, [])
    tasks = planner.from_raw([
        {"id": "a", "agent": "coder", "task": "write the summary"},
        {"id": "b", "agent": "coder", "task": "write the tests", "depends_on": ["a"]},
        {"id": "c", "agent": "coder", "task": "publish what uses the summary", "depends_on": ["a"]},
        {"id": "d", "agent": "coder", "task": "loop", "depends_on": ["e"]},
        {"id": "e", "agent": "coder", "task": "loop back", "depends_on": ["d", "zzz"]},
    ])
    by = {t.id: t for t in tasks}
    # The unknown dependency is dropped and the cycle broken: one of its two edges stays.
    assert sorted(by["d"].depends_on + by["e"].depends_on) in (["d"], ["e"])
    dropped = await planner.prune(ctx, "goal", tasks)
    assert dropped == 2
    assert by["b"].depends_on == [] and by["c"].depends_on == ["a"]


async def test_tasks_run_in_parallel_and_wait_only_for_what_they_need(platform: Platform, tmp_path: Path) -> None:
    platform.workers[CODER["account_id"]] = (0.4, lambda body: "coder did: " + body.split("]", 1)[1].split("\n")[0].strip())
    ctx, store = context(platform, tmp_path, [], decision=False)
    [_, run] = swarm_tools(ctx, store)
    started = time.monotonic()
    report = await run.ainvoke({"goal": "a site", "tasks": [
        {"id": "pages", "agent": "coder", "task": "build the pages"},
        {"id": "api", "agent": "coder", "task": "build the api"},
        {"id": "styles", "agent": "coder", "task": "write the styles"},
        {"id": "deploy", "agent": "coder", "task": "deploy the site", "depends_on": ["pages", "api"]},
    ]})
    elapsed = time.monotonic() - started
    # Three independent tasks for the same agent at once, then the dependent one.
    assert platform.most_working == 3
    assert elapsed < 1.4, elapsed
    assert "4 done" in report
    handoffs = [m for m in platform.messages if m["mentions"] == [CODER["account_id"]]]
    assert len(handoffs) == 4 and all("[task " in m["body"] for m in handoffs)
    deploy = next(m for m in handoffs if "deploy the site" in m["body"])
    assert "coder did: build the pages" in deploy["body"] and "coder did: build the api" in deploy["body"]
    assert any(e.get("text", "").startswith("Swarm plan\n") for e in platform.logs)


async def test_a_failed_task_skips_what_depends_on_it(platform: Platform, tmp_path: Path) -> None:
    platform.workers[CODER["account_id"]] = (0.05, lambda body: "ok")
    ctx, store = context(platform, tmp_path, [], decision=False)
    [_, run] = swarm_tools(ctx, store)
    report = await run.ainvoke({"goal": "x", "tasks": [
        {"id": "a", "agent": "nobody-here", "task": "impossible"},
        {"id": "b", "agent": "coder", "task": "after a", "depends_on": ["a"]},
        {"id": "c", "agent": "coder", "task": "independent"},
    ]})
    assert "1 done" in report and "1 failed" in report and "1 skipped" in report


async def test_the_plan_is_written_from_the_goal_and_the_team(platform: Platform, tmp_path: Path) -> None:
    platform.workers[CODER["account_id"]] = (0.05, lambda body: "done")
    platform.decide = lambda state, qs: {k: {"probability": 0.05} for k in qs}
    ctx, store = context(platform, tmp_path, [
        js({"tasks": [{"id": "t1", "agent": "coder", "task": "part one"},
                      {"id": "t2", "agent": "coder", "task": "part two", "depends_on": ["t1"]}]}),
    ])
    [_, run] = swarm_tools(ctx, store)
    report = await run.ainvoke({"goal": "do it in two parts"})
    assert "2 done" in report
    # The dependency was not needed: both ran at once.
    assert "(after t1)" not in report
    assert any("dependencies are not needed" in e.get("text", "") for e in platform.logs)


async def test_a_busy_agent_takes_a_task_as_a_parallel_instance(platform: Platform, tmp_path: Path) -> None:
    model = ScriptedModel(script=[AIMessage(content="instance answer")])
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda a, g: model,
               gateway_factory=platform.gateway)
    main = f"{CODER['vm_id']}:space-1:room-1"
    platform.post("acc-ann", "a room message")
    async with r._lock(main):  # the coder is working in the room
        out = await r.prompt(turn_request(CODER, "@coder [task abc123def0] build the api", token="tok-coder"))
    assert out.reply == "instance answer"
    # Untagged work would have waited; a tagged task ran on a thread of its own.
    assert r.store.seen(main + ":task:abc123def0")
    # An idle agent takes a tagged task on its own thread in the room.
    model.script.append(AIMessage(content="main answer"))
    platform.post("acc-ann", "another room message")
    out = await r.prompt(turn_request(CODER, "@coder [task ffff000011] more", token="tok-coder"))
    assert out.reply == "main answer" and r.store.seen(main)


async def test_the_lead_has_the_swarm_tools(platform: Platform, tmp_path: Path) -> None:
    platform.workers[CODER["account_id"]] = (0.05, lambda body: "built")
    model = ScriptedModel(script=[
        call("run_swarm", {"goal": "g", "tasks": [{"id": "x", "agent": "coder", "task": "build"}]}),
        AIMessage(content="all built"),
    ])
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda a, g: model,
               gateway_factory=platform.gateway)
    out = await r.prompt(turn_request(LEAD, "build", token="tok-lead", role="lead"))
    assert out.reply == "all built"
    result = next(str(m.content) for convo in model.seen for m in convo if getattr(m, "name", "") == "run_swarm")
    assert "1 done" in result and "built" in result
