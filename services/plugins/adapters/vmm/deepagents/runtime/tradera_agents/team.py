"""Who is in the space: people, agents and tools, and how to address them."""

from __future__ import annotations

import asyncio
import re
import time
import uuid
from dataclasses import dataclass
from typing import Any

from .context import TurnContext
from .gateway import GatewayError


@dataclass
class Member:
    account_id: str
    name: str
    kind: str  # "person", "agent", "tool" (an app)
    bot_id: str = ""
    description: str = ""
    runtime: bool = False  # an agent of the deep agents runtime (can take tasks)
    lead: bool = False  # the space's lead agent

#: The VM id of the platform's built-in lead agent.
LEAD_VM = "deepagents-tradera"


async def team(ctx: TurnContext) -> list[Member]:
    """The space's members as the agent sees them (itself excluded)."""
    bots, people = await asyncio.gather(
        ctx.gateway.call("spaces", "bots_list", {"space": ctx.space}),
        ctx.gateway.call("spaces", "members_list", {"space": ctx.space, "limit": 200}),
        return_exceptions=True,
    )
    out: list[Member] = []
    bot_accounts: set[str] = set()
    if isinstance(bots, dict):
        for b in bots.get("bots") or []:
            account = b.get("account_id", "")
            bot_accounts.add(account)
            bot_accounts.add(b.get("member_id", ""))
            if account == ctx.agent.account_id or b.get("id") == ctx.agent.bot_id:
                continue
            kind = b.get("kind", "")
            out.append(Member(account_id=account, name=b.get("name", ""), kind=kind, bot_id=b.get("id", ""),
                              description=b.get("description", ""),
                              runtime=kind == "agent" and b.get("vm_type", "") in ("deepagents", "langchain", "grok", ""),
                              lead=b.get("vm_id", "") == LEAD_VM))
    if isinstance(people, dict):
        seen: set[str] = set()
        for m in people.get("members") or []:
            member = m.get("member_id", "")
            if member in bot_accounts or member in seen or m.get("role") == "bot" or m.get("kind") == "bot":
                continue
            seen.add(member)
            out.append(Member(account_id=member, name=m.get("handle", "") or member, kind="person",
                              description=m.get("role", "")))
    return out


def find(members: list[Member], who: str) -> Member | None:
    """Resolve a name, @handle, bot id or account id."""
    key = who.strip().lstrip("@").lower()
    for m in members:
        if key in (m.account_id.lower(), m.bot_id.lower(), m.name.lower()):
            return m
    return None


def describe(members: list[Member]) -> str:
    lines = []
    for kind, title in (("agent", "Agents"), ("person", "People"), ("tool", "Apps")):
        group = [m for m in members if m.kind == kind]
        if not group:
            continue
        lines.append(f"{title}:")
        for m in group:
            entry = f"- {m.name} (account {m.account_id}"
            if m.bot_id:
                entry += f", bot {m.bot_id}"
            entry += ")"
            if m.description:
                entry += f": {m.description[:200]}"
            lines.append(entry)
    return "\n".join(lines) or "Nobody else is in this space yet."


_SAFE = re.compile(r"[^a-zA-Z0-9_-]+")


def subagent_name(m: Member) -> str:
    return _SAFE.sub("-", m.name).strip("-") or m.bot_id


# --- delegating work over room messaging -------------------------------------

#: How long a delegated task may take before the delegator stops waiting.
TASK_TIMEOUT = 45 * 60.0
POLL_EVERY = 2.0

#: Every delegated task carries a tag. An agent that is already working in the
#: room when a tagged task reaches it takes the task as a parallel instance of
#: itself, on a thread of its own, instead of queueing behind its current work:
#: so several tasks for the same agent run at once.
TASK_TAG = re.compile(r"\[task ([a-z0-9]{6,32})\]")


def new_tag() -> str:
    return uuid.uuid4().hex[:10]


def task_tag(message: str) -> str:
    """The tag of a delegated task message, or ''."""
    m = TASK_TAG.search(message or "")
    return m.group(1) if m else ""


def task_id(message_id: str, account_id: str) -> str:
    return f"{message_id}:{account_id}"


def split_task_id(tid: str) -> tuple[str, str]:
    message_id, _, account = tid.partition(":")
    return message_id, account


async def assign(ctx: TurnContext, member: Member, task: str, *, tag: str = "") -> str:
    """Post a task to an agent in the room (an @mention starts its turn) and
    return the task id its answer will be correlated with."""
    body = f"@{member.name} [task {tag or new_tag()}] {task}"
    out = await ctx.gateway.call("spaces", "message_send", {
        "space": ctx.space, "room": ctx.room, "body": body, "mentions": [member.account_id],
    })
    return task_id(out["message_id"], member.account_id)


async def answer(ctx: TurnContext, tid: str) -> dict[str, Any] | None:
    """The answer an agent posted to a task, if it has answered."""
    message_id, account = split_task_id(tid)
    out = await ctx.gateway.call("spaces", "message_list", {
        "space": ctx.space, "room": ctx.room, "reply_to": message_id, "limit": 20,
    })
    for m in reversed(out.get("messages") or []):  # newest first → oldest first
        if m.get("sender_id") == account and m.get("kind", "") != "log":
            return m
    return None


async def wait(ctx: TurnContext, tid: str, timeout: float = TASK_TIMEOUT) -> str:
    """Wait for an agent's answer to a task."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            m = await answer(ctx, tid)
        except GatewayError as exc:
            if exc.status in (401, 403):
                raise
            m = None
        if m is not None:
            return str(m.get("body", "")).strip() or "(the agent answered with no text)"
        if time.monotonic() >= deadline:
            return (f"(no answer yet after {int(timeout)}s; the task {tid} is still open. Do not poll for it in a "
                    "loop: go on with other work, or finish your answer and say this task is still running)")
        await asyncio.sleep(POLL_EVERY)
