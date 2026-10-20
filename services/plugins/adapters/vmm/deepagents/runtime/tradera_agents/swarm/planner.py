"""A goal as a plan of tasks the team runs in parallel.

A plan is a set of tasks, each for one agent, with the tasks it must wait for.
The language model writes it from the goal and the team; the decision model
then checks every dependency it wrote — "does this task really need that
one's result before it can start?" — and the ones it is confident are not
needed are dropped, so independent work starts at once instead of in line.
Several tasks may go to the same agent: they run as parallel instances of it.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any

from .. import team as teamlib
from ..context import TurnContext
from ..decision import routing
from ..decision.client import probability
from . import llm

log = logging.getLogger("tradera.agents.swarm")

#: A dependency the decision model gives less than this is not needed.
NOT_NEEDED_BELOW = 0.25
#: At most this many tasks in a plan.
MAX_TASKS = 24

_ID = re.compile(r"[^a-z0-9_-]+")


@dataclass
class Task:
    id: str
    task: str
    agent: str = ""  # a member's name, as planned
    role: str = ""
    depends_on: list[str] = field(default_factory=list)
    member: teamlib.Member | None = None
    status: str = "pending"  # pending | running | done | failed | skipped
    result: str = ""
    seconds: float = 0.0
    attempts: int = 0

    def json(self) -> dict[str, Any]:
        return {"id": self.id, "agent": self.member.name if self.member else self.agent, "task": self.task,
                "depends_on": self.depends_on, "status": self.status, "seconds": round(self.seconds, 1)}


def _tid(raw: Any, i: int, taken: set[str]) -> str:
    base = _ID.sub("-", str(raw or f"t{i + 1}").lower()).strip("-")[:24] or f"t{i + 1}"
    tid, n = base, 2
    while tid in taken:
        tid, n = f"{base}-{n}", n + 1
    taken.add(tid)
    return tid


def from_raw(raw_tasks: list[Any]) -> list[Task]:
    """Tasks as the lead (or the language model) wrote them."""
    taken: set[str] = set()
    tasks: list[Task] = []
    ids: dict[str, str] = {}
    for i, raw in enumerate(raw_tasks[:MAX_TASKS]):
        if not isinstance(raw, dict) or not str(raw.get("task") or "").strip():
            continue
        tid = _tid(raw.get("id"), i, taken)
        ids[str(raw.get("id") or tid)] = tid
        deps = raw.get("depends_on") or []
        tasks.append(Task(id=tid, task=str(raw["task"]).strip(), agent=str(raw.get("agent") or "").strip(),
                          role=str(raw.get("role") or "").strip(),
                          depends_on=[str(d) for d in deps] if isinstance(deps, list) else [str(deps)]))
    known = {t.id for t in tasks}
    for t in tasks:
        t.depends_on = [ids.get(d, d) for d in t.depends_on]
        t.depends_on = list(dict.fromkeys(d for d in t.depends_on if d in known and d != t.id))
    break_cycles(tasks)
    return tasks


def break_cycles(tasks: list[Task]) -> None:
    """Drop the dependencies that close a cycle, so every task can run."""
    by_id = {t.id: t for t in tasks}
    state: dict[str, int] = {}

    def visit(t: Task) -> None:
        state[t.id] = 1
        for dep in list(t.depends_on):
            if state.get(dep) == 1:
                t.depends_on.remove(dep)  # back edge
            elif state.get(dep) is None:
                visit(by_id[dep])
        state[t.id] = 2

    for t in tasks:
        if state.get(t.id) is None:
            visit(t)


async def resolve(ctx: TurnContext, tasks: list[Task], members: list[teamlib.Member],
                  roster: dict[str, teamlib.Member]) -> None:
    """Give every task its agent: by name, by role on the team, else the agent
    the decision model finds fits the task."""
    agents = [m for m in members if m.kind == "agent" and m.runtime and not m.lead]
    for t in tasks:
        m = teamlib.find(agents, t.agent) if t.agent else None
        if m is None and (t.role or t.agent) in roster:
            m = roster[t.role or t.agent]
        if m is None and t.agent:
            m = next((x for x in agents if t.agent.lower() in x.name.lower()), None)
        if m is None and ctx.decision is not None:
            m = await routing.best_agent(ctx.decision, f"Addressed to: {t.agent or t.role}\n{t.task}", agents)
        t.member = m


PLAN_SYSTEM = (
    "You plan work for a team of AI agents that run tasks in parallel. Answer only in JSON. Split the goal into "
    "tasks, each self-contained (goal, inputs under /workspace, expected result and where to put it) and for one "
    "agent of the team. Make independent work separate tasks so it runs at the same time; split a large uniform "
    "job into several tasks for the same agent (they run as parallel instances). Add a dependency only when a "
    "task needs another's result to start. Do not plan the final integration: the lead does it."
)


async def plan(ctx: TurnContext, goal: str, members: list[teamlib.Member], roster_text: str = "") -> list[Task]:
    """The language model's plan for the goal, with the team it has."""
    agents = [m for m in members if m.kind == "agent" and m.runtime and not m.lead]
    team = roster_text or "\n".join(f"- {m.name}: {m.description[:200]}" for m in agents) or "(no agents yet)"
    answer = await llm.ask_json(ctx, PLAN_SYSTEM, (
        f"Goal:\n{goal}\n\nTeam:\n{team}\n\nAnswer as {{\"tasks\": [{{\"id\": \"t1\", \"agent\": \"<agent name>\", "
        "\"task\": \"...\", \"depends_on\": []}]}}"))
    raw = answer.get("tasks") if isinstance(answer, dict) else answer if isinstance(answer, list) else None
    return from_raw(raw or [])


async def prune(ctx: TurnContext, goal: str, tasks: list[Task]) -> int:
    """Drop the dependencies the decision model is confident are not needed;
    returns how many were dropped."""
    if ctx.decision is None:
        return 0
    by_id = {t.id: t for t in tasks}
    questions: dict[str, Any] = {}
    edges: dict[str, tuple[str, str]] = {}
    for t in tasks:
        for dep in t.depends_on:
            qid = f"e{len(edges)}"
            edges[qid] = (t.id, dep)
            questions[qid] = {
                "type": "boolean",
                "instructions": (f"Does task B need the result of task A before it can start?\n"
                                 f"A: {by_id[dep].task[:800]}\nB: {t.task[:800]}"),
                "criteria": {"true": "B uses what A produces (its files, findings or decisions) as an input",
                             "false": "B can be done from the goal and its own inputs, at the same time as A"}}
    if not questions:
        return 0
    answers = await ctx.decision.evaluate({"goal": goal[-3000:]}, questions)
    dropped = 0
    for qid, (tid, dep) in edges.items():
        p = probability(answers, qid)
        if p is not None and p < NOT_NEEDED_BELOW:
            by_id[tid].depends_on.remove(dep)
            dropped += 1
    return dropped
