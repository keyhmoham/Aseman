"""The deep agents ``task`` tool over the platform's messaging.

A subagent of a tradera agent is another agent of the space, running its
own turn on its own thread in this runtime. ``task`` hands it the work as a
room message that mentions it, and the answer it posts in reply (``reply_to``)
is the subagent's result — so people see every hand-off and answer in the
room, can talk to any subagent directly, and every agent works on the same
sandbox.

``general-purpose`` is the space's generalist agent, recruited into the space
the first time somebody needs it.
"""

from __future__ import annotations

from typing import Any

from deepagents import CompiledSubAgent
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.runnables import RunnableLambda

from . import team as teamlib
from .context import TurnContext
from .gateway import GatewayError

GENERALIST = "generalist"
GENERALIST_DESCRIPTION = "General-purpose agent for research, multi-step work and anything no specialist covers."
GENERALIST_INSTRUCTIONS = (
    "You are the space's general-purpose agent. Take any self-contained task, work it through end to end "
    "in the shared sandbox and answer with a complete, concise result: what you found or built and where it is."
)


def _task_text(state: dict[str, Any]) -> str:
    for m in reversed(state.get("messages") or []):
        if isinstance(m, HumanMessage):
            return m.text if hasattr(m, "text") else str(m.content)
    return ""


HANDOVER_FAILED = "The task could not be handed over: "


def _runnable(ctx: TurnContext, resolve: Any, *, tag: str = "", timeout: float = teamlib.TASK_TIMEOUT) -> RunnableLambda:
    """A subagent's runnable: the task goes to the agent as a room message and
    its answer there is the result. ``tag`` names the task (team.TASK_TAG), so a
    busy agent takes it as a parallel instance."""

    async def run(state: dict[str, Any]) -> dict[str, Any]:
        task = _task_text(state)
        try:
            member = await resolve()
            tid = await teamlib.assign(ctx, member, task, tag=tag)
            reply = await teamlib.wait(ctx, tid, timeout)
        except GatewayError as exc:
            reply = HANDOVER_FAILED + str(exc)
        return {"messages": [AIMessage(content=reply)]}

    return RunnableLambda(run)


def member_subagent(ctx: TurnContext, member: teamlib.Member, *, tag: str = "",
                    timeout: float = teamlib.TASK_TIMEOUT) -> CompiledSubAgent:
    """One of the space's agents as a deep agents subagent."""

    async def fixed() -> teamlib.Member:
        return member

    return CompiledSubAgent(name=teamlib.subagent_name(member), description=member.description or f"The space's {member.name} agent.",
                            runnable=_runnable(ctx, fixed, tag=tag, timeout=timeout))


async def subagents(ctx: TurnContext, members: list[teamlib.Member]) -> list[CompiledSubAgent]:
    out: list[CompiledSubAgent] = []
    names: set[str] = set()
    generalist = next((m for m in members if m.kind == "agent" and m.name.startswith(GENERALIST)), None)
    for m in members:
        if m.kind != "agent" or not m.runtime or m is generalist:
            continue
        # Nobody delegates up to the lead: it is the one waiting on the team.
        if m.lead:
            continue
        name = teamlib.subagent_name(m)
        if name in names or name == "general-purpose":
            continue
        names.add(name)
        out.append(member_subagent(ctx, m))

    async def generalist_member() -> teamlib.Member:
        nonlocal generalist
        if generalist is None:
            res = await ctx.gateway.call("spaces", "agent_recruit", {
                "space": ctx.space, "room": ctx.room, "name": GENERALIST, "description": GENERALIST_DESCRIPTION,
                "instructions": GENERALIST_INSTRUCTIONS,
            })
            generalist = teamlib.Member(account_id=res["account_id"], name=res["name"], kind="agent",
                                        bot_id=res["bot_id"], description=GENERALIST_DESCRIPTION, runtime=True)
        return generalist

    out.append(CompiledSubAgent(
        name="general-purpose",
        description=(generalist.description if generalist else GENERALIST_DESCRIPTION)
        + " Runs as the space's generalist agent, in the room and the shared sandbox.",
        runnable=_runnable(ctx, generalist_member)))
    return out
