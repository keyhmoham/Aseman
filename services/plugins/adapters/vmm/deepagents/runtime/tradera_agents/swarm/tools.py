"""The lead's swarm tools: set up a team, then run a plan with it in parallel."""

from __future__ import annotations

from typing import Any

from langchain_core.tools import BaseTool, tool

from .. import team as teamlib
from ..context import TurnContext
from ..store import Store
from ..worklog import WorkLog
from . import executor, planner, team_setup


def _roster(ctx: TurnContext, store: Store, members: list[teamlib.Member]) -> tuple[dict[str, teamlib.Member], str]:
    """The last team set up on this thread: role → member, and as text for planning."""
    saved = store.team(ctx.base_thread) or {}
    roster: dict[str, teamlib.Member] = {}
    lines = []
    for role in saved.get("roles") or []:
        m = teamlib.find(members, role.get("account_id") or "") or teamlib.find(members, role.get("agent") or "")
        if m is None:
            continue
        roster[role["role"]] = m
        lines.append(f"- {m.name} — role `{role['role']}` ({role.get('title', '')}): {role.get('needs', '')[:300]}"
                     + (f" [up to {role['instances']} in parallel]" if (role.get("instances") or 1) > 1 else ""))
    return roster, "\n".join(lines)


def swarm_tools(ctx: TurnContext, store: Store) -> list[BaseTool]:
    worklog = WorkLog(ctx)

    @tool
    async def assemble_team(goal: str, max_agents: int = 5, generate: bool = True) -> str:
        """Set up the team a goal needs before you run it.

        Breaks the goal into the specialist roles it needs, then staffs each
        role with the best fit: an agent already in the space, else one
        published in the marketplace (hired into the space), else a new
        specialist written for the role (when generate is true). Returns the
        roster; plan with it in run_swarm. Use it for work that needs more than
        one specialist; small work you do yourself or delegate directly.
        """
        team = await team_setup.assemble(ctx, goal, max_roles=max(1, min(max_agents, team_setup.MAX_ROLES)),
                                         generate=generate)
        store.put_team(ctx.base_thread, team.json())
        await worklog.write("Team\n" + team.describe())
        return team.describe() + "\n\nRun the work with run_swarm (tasks for these agents run in parallel)."

    @tool
    async def run_swarm(goal: str, tasks: list[dict[str, Any]] | None = None) -> str:
        """Run work across the team in parallel and return every task's result.

        tasks: the plan, [{id, agent, task, depends_on: [ids]}]: each task
        self-contained (goal, inputs under /workspace, expected result and
        where to put it) and for one agent of the space (or a role of the team
        set up with assemble_team). Independent tasks run at the same time;
        several tasks for the same agent run as parallel instances of it; a
        task starts once the tasks in its depends_on are done, with their
        results. Leave tasks out to have the plan written from the goal and
        the team. Integrate and check the results yourself before you answer.
        """
        members = await teamlib.team(ctx)
        roster, roster_text = _roster(ctx, store, members)
        given = planner.from_raw(tasks) if tasks else None
        flow = executor.graph(ctx, members, roster, worklog=worklog.write)
        state = await flow.ainvoke({"goal": goal, "tasks": given or [], "roster": roster_text})
        plan = state.get("tasks") or []
        if plan:
            await worklog.write("Swarm plan\n" + "\n".join(
                f"- {t.id} → {t.member.name if t.member else t.agent or '?'}"
                + (f" (after {', '.join(t.depends_on)})" if t.depends_on else "") + f": {t.status}" for t in plan))
        return state.get("report") or "No tasks were planned."

    return [assemble_team, run_swarm]



