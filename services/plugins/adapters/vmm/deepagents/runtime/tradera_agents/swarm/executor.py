"""Running a plan: every task as soon as what it waits for is done.

The swarm is a LangGraph flow — plan, prune, run, report — whose run step
schedules the plan's tasks dynamically: a task starts the moment its
dependencies are done (not when a whole wave is), up to a number at once.
Each task goes to its agent as a deep agents subagent of the space
(subagents.member_subagent): a room message people see, answered in the room,
in the agent's own turn and backbone. Tasks for the same agent run as parallel
instances of it (team.TASK_TAG). A task waits with the results of the tasks it
builds on; a task whose dependency failed is skipped, and a hand-over that
failed is tried once more.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Any, Awaitable, Callable, TypedDict

from langchain_core.messages import HumanMessage
from langgraph.graph import END, START, StateGraph

from .. import subagents, team as teamlib
from ..context import TurnContext
from . import planner
from .planner import Task

log = logging.getLogger("tradera.agents.swarm")

#: Tasks running at once, at most.
PARALLEL = 8
#: A dependency's result shown to a task, at most (characters).
DEP_RESULT_CHARS = 3000
#: How long one task may take.
TASK_TIMEOUT = teamlib.TASK_TIMEOUT

_NO_ANSWER = "(no answer yet after"


def parallel() -> int:
    try:
        return max(1, int(os.environ.get("TRADERA_SWARM_PARALLEL", "") or PARALLEL))
    except ValueError:
        return PARALLEL


def brief(goal: str, task: Task, done: dict[str, Task], total: int) -> str:
    """What the agent is handed: its task, where it fits, and what it builds on."""
    parts = [task.task, "",
             f"(Task {task.id} of a team plan of {total} for: {goal[:600]}. Other agents work on other tasks at the "
             "same time: do only this part, and answer with its result — what you found or made and where it is.)"]
    deps = [done[d] for d in task.depends_on if d in done]
    if deps:
        parts.append("\nResults of the tasks this one builds on:")
        for d in deps:
            who = d.member.name if d.member else d.agent
            text = d.result if len(d.result) <= DEP_RESULT_CHARS else d.result[:DEP_RESULT_CHARS] + "…"
            parts.append(f"[{d.id} by {who}]\n{text}")
    return "\n".join(parts)


Log = Callable[[str], Awaitable[None]]


async def run_tasks(ctx: TurnContext, goal: str, tasks: list[Task], *, limit: int | None = None,
                    worklog: Log | None = None, swarm_id: str = "") -> list[Task]:
    """Run the tasks, each as soon as it can start, at most ``limit`` at once."""
    limit = limit or parallel()
    swarm_id = swarm_id or teamlib.new_tag()[:6]
    by_id = {t.id: t for t in tasks}
    done: dict[str, Task] = {}
    running: dict[asyncio.Task[Any], Task] = {}
    started_at: dict[str, float] = {}

    async def note(text: str) -> None:
        if worklog is not None:
            await worklog(text)

    async def work(task: Task) -> None:
        member = task.member
        assert member is not None
        sub = subagents.member_subagent(ctx, member, tag=f"{swarm_id}{task.id.replace('-', '')}"[:32].lower(),
                                        timeout=TASK_TIMEOUT)
        for attempt in (1, 2):
            task.attempts = attempt
            out = await sub["runnable"].ainvoke({"messages": [HumanMessage(content=brief(goal, task, done, len(tasks)))]})
            reply = str(out["messages"][-1].content)
            if reply.startswith(subagents.HANDOVER_FAILED) and attempt == 1:
                continue
            task.result = reply
            task.status = "failed" if reply.startswith((subagents.HANDOVER_FAILED, _NO_ANSWER)) else "done"
            return

    def ready(task: Task) -> bool:
        return task.status == "pending" and all(by_id[d].status == "done" for d in task.depends_on)

    def blocked(task: Task) -> bool:
        return task.status == "pending" and any(by_id[d].status in ("failed", "skipped") for d in task.depends_on)

    while True:
        for t in tasks:
            if t.status == "pending" and t.member is None:
                t.status, t.result = "failed", "no agent of the space can take it (name an agent of the team)"
                await note(f"Swarm · {t.id} has no agent")
            elif blocked(t):
                t.status = "skipped"
                t.result = "not run: a task it builds on did not finish (" + ", ".join(
                    d for d in t.depends_on if by_id[d].status != "done") + ")"
                await note(f"Swarm · {t.id} skipped: a task it builds on did not finish")
        for t in tasks:
            if len(running) >= limit:
                break
            if ready(t):
                t.status = "running"
                started_at[t.id] = time.monotonic()
                running[asyncio.create_task(work(t))] = t
                await note(f"Swarm · started {t.id} with {t.member.name}: {t.task[:200]}")
        if not running:
            break
        finished, _ = await asyncio.wait(list(running), return_when=asyncio.FIRST_COMPLETED)
        for job in finished:
            t = running.pop(job)
            t.seconds = time.monotonic() - started_at[t.id]
            if job.exception() is not None:
                t.status, t.result = "failed", f"error: {job.exception()}"
            done[t.id] = t
            await note(f"Swarm · {t.id} {t.status} after {t.seconds:.0f}s ({t.member.name if t.member else '?'})")
    return tasks


def report(tasks: list[Task], *, clip: int = 6000) -> str:
    """The plan's outcome for the lead, task by task."""
    if not tasks:
        return "No tasks were planned."
    counts: dict[str, int] = {}
    for t in tasks:
        counts[t.status] = counts.get(t.status, 0) + 1
    lines = ["Swarm finished: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items()))]
    for t in tasks:
        who = t.member.name if t.member else (t.agent or "?")
        deps = f" (after {', '.join(t.depends_on)})" if t.depends_on else ""
        result = t.result if len(t.result) <= clip else t.result[:clip] + "…"
        lines.append(f"\n## {t.id} · {who} · {t.status} · {t.seconds:.0f}s{deps}\n{t.task[:300]}\n→ {result}")
    return "\n".join(lines)


class SwarmState(TypedDict, total=False):
    goal: str
    tasks: list[Task]
    roster: str
    pruned: int
    report: str


def graph(ctx: TurnContext, members: list[teamlib.Member], roster: dict[str, teamlib.Member],
          worklog: Log | None = None) -> Any:
    """The swarm flow for one turn: plan (unless the lead gave tasks), prune
    the dependencies that are not needed, run, report."""

    async def plan_node(state: SwarmState) -> SwarmState:
        tasks = state.get("tasks") or await planner.plan(ctx, state["goal"], members, state.get("roster", ""))
        await planner.resolve(ctx, tasks, members, roster)
        return {"tasks": tasks}

    async def prune_node(state: SwarmState) -> SwarmState:
        dropped = await planner.prune(ctx, state["goal"], state["tasks"])
        if dropped and worklog is not None:
            await worklog(f"Swarm · decision model: {dropped} dependencies are not needed; those tasks run in parallel")
        return {"pruned": dropped}

    async def run_node(state: SwarmState) -> SwarmState:
        return {"tasks": await run_tasks(ctx, state["goal"], state["tasks"], worklog=worklog)}

    async def report_node(state: SwarmState) -> SwarmState:
        return {"report": report(state["tasks"])}

    g = StateGraph(SwarmState)
    g.add_node("plan", plan_node)
    g.add_node("prune", prune_node)
    g.add_node("run", run_node)
    g.add_node("report", report_node)
    g.add_edge(START, "plan")
    g.add_edge("plan", "prune")
    g.add_edge("prune", "run")
    g.add_edge("run", "report")
    g.add_edge("report", END)
    return g.compile()
