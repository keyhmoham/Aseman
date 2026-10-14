"""The platform tools of a deep agent.

Nothing here talks to anything but the node's action API:

* conversation — room messages (``spaces.message_send`` / ``message_list``)
  and direct messages (``users.dm_send`` / ``dm_list``);
* delegation — handing tasks to the space's agents is a room message that
  mentions them, and their answer is the message they post in reply;
* tools — tool and miniapp bots and the platform's own tools (files, images,
  previews, routines) are all ``spaces.ask``;
* the swarm — ``spaces.agent_recruit`` adds a specialist to the space.

The shell and files of the shared sandbox are the deep agents filesystem and
``execute`` tools (see sandbox.py); people are asked through ``ask_user``,
which pauses the agent's thread until a person answers in the room.
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from langchain_core.tools import BaseTool, StructuredTool, tool

from . import team as teamlib
from .context import TurnContext
from .gateway import GatewayError

# Platform tools agents reach through spaces.ask, under the name the agent
# sees. The shell and sandbox files are the deep agents tools instead, and
# messaging and questions have tools of their own.
PLATFORM_TOOLS = {
    "file_send": "file_send",
    "file_upload": "file_upload",
    "file_read": "read_attachment",
    "image_generate": "image_generate",
    "proxy_create": "proxy_create",
    "proxy_list": "proxy_list",
    "proxy_get": "proxy_get",
    "proxy_delete": "proxy_delete",
    "routine_create": "routine_create",
    "routine_list": "routine_list",
    "routine_get": "routine_get",
    "routine_update": "routine_update",
    "routine_delete": "routine_delete",
    # Widgets: A2UI composed from the space's tools' data and frontends.
    "ui_compose": "compose_ui",
    # The room's desk: a tool's own generative frontend, filled with a result
    # the agent got, opens as a card window; agents arrange and close them.
    "frontend_show": "frontend_show",
    "desk_state": "desk_state",
    "desk_arrange": "desk_arrange",
    "desk_close": "desk_close",
}

# Tools every agent keeps whatever its allowed_tools say: without them it can
# neither talk nor report.
CORE_TOOLS = {"send_message", "read_room", "list_team", "ask_user", "send_direct_message", "read_direct_messages",
              "start_task", "check_tasks", "wait_tasks", "frontend_show", "desk_state", "desk_arrange", "desk_close"}

_SLUG = re.compile(r"[^a-z0-9_]+")
# How long check_tasks waits for a first answer before reporting all still running.
CHECK_WAIT = 20.0


def _err(exc: Exception) -> str:
    return f"error: {exc}"


def _clip(text: str, n: int = 4000) -> str:
    return text if len(text) <= n else text[:n] + "…"


def _format_messages(messages: list[dict[str, Any]], clip: int = 2000) -> str:
    lines = []
    for m in messages:
        sender = m.get("sender") or {}
        name = sender.get("display_name") or sender.get("handle") or m.get("sender_id", "?")
        kind = m.get("kind") or "message"
        tag = "" if kind in ("", "text", "message") else f" [{kind}]"
        reply = f" (reply to {m['reply_to']})" if m.get("reply_to") else ""
        files = ", ".join(a.get("name", "") + " #" + a.get("id", "") for a in m.get("attachments") or [])
        lines.append(f"[{m.get('created_at', '')}] {name}{tag}{reply} (message {m.get('id', '')}): "
                     f"{_clip(str(m.get('body', '')), clip)}" + (f"\n  files: {files}" if files else ""))
    return "\n".join(lines)


def communication_tools(ctx: TurnContext) -> list[BaseTool]:
    gw = ctx.gateway

    @tool
    async def send_message(body: str, mention: list[str] | None = None, reply_to: str = "") -> str:
        """Post a message in this room while you work.

        Use it for progress worth reporting and for talking to other people or
        agents. It is NOT how you answer the message you are working on: your
        final answer is posted in the room as the reply to it, once.
        mention: names or ids of people/agents to address. Mentioning an agent
        starts its turn on the message (use start_task when you need to track
        its answer). reply_to: the id of another message this one answers.
        """
        if reply_to and reply_to == ctx.turn.message_id:
            # One channel for the answer: the turn's final answer is stored as
            # the reply to this message. Posting it here too is how the room
            # got the same answer twice.
            return ("Not posted: that is the message you are answering. Give this text as your final answer "
                    "instead; it is posted in the room as the reply. Do not send it with send_message.")
        mentions: list[str] = []
        if mention:
            members = await teamlib.team(ctx)
            for who in mention:
                m = teamlib.find(members, who)
                mentions.append(m.account_id if m else who)
        try:
            out = await gw.call("spaces", "message_send", {
                "space": ctx.space, "room": ctx.room, "body": body, "mentions": mentions or None,
                "reply_to": reply_to or None,
            })
        except GatewayError as exc:
            return _err(exc)
        return f"posted message {out.get('message_id', '')}"

    @tool
    async def read_room(limit: int = 30, reply_to: str = "") -> str:
        """Read the latest messages of this room (oldest first).

        reply_to: only the answers to that message.
        """
        try:
            out = await gw.call("spaces", "message_list", {
                "space": ctx.space, "room": ctx.room, "limit": max(1, min(limit, 200)), "reply_to": reply_to or None,
            })
        except GatewayError as exc:
            return _err(exc)
        messages = list(reversed(out.get("messages") or []))
        return _format_messages(messages) or "(no messages)"

    @tool
    async def list_team() -> str:
        """The people, agents, tools and miniapps of this space, with their ids."""
        return teamlib.describe(await teamlib.team(ctx))

    @tool
    async def send_direct_message(to: str, body: str) -> str:
        """Send a private direct message to a person or agent (name or account id).

        A direct message to an agent starts a conversation with it; its answer
        arrives as a direct message (read_direct_messages).
        """
        members = await teamlib.team(ctx)
        m = teamlib.find(members, to)
        try:
            out = await gw.call("users", "dm_send", {"to": m.account_id if m else to, "body": body})
        except GatewayError as exc:
            return _err(exc)
        return f"sent direct message {out.get('id', '')}"

    @tool
    async def read_direct_messages(peer: str, limit: int = 30) -> str:
        """Read your direct conversation with a person or agent (name or account id)."""
        members = await teamlib.team(ctx)
        m = teamlib.find(members, peer)
        try:
            out = await gw.call("users", "dm_list", {"peer": m.account_id if m else peer, "limit": max(1, min(limit, 200))})
        except GatewayError as exc:
            return _err(exc)
        lines = []
        for d in out.get("messages") or []:
            who = "you" if d.get("from_id", d.get("from")) == ctx.agent.account_id else (m.name if m else peer)
            lines.append(f"[{d.get('created_at', '')}] {who}: {_clip(str(d.get('body', '')), 2000)}")
        return "\n".join(lines) or "(no direct messages)"

    @tool
    def ask_user(question: str, options: list[str] | None = None) -> str:
        """Ask the people in this room a question and wait for their answer.

        Use it when only a person can decide or supply something essential.
        Your work pauses until somebody answers; the answer is the result.
        options: up to 3 suggested answers, recommended first.
        """
        # Never runs: the human-in-the-loop interrupt answers on its behalf.
        return "No answer was given."

    tools = [send_message, list_team, send_direct_message, ask_user]
    if not ctx.turn.no_memory:
        tools += [read_room, read_direct_messages]
    return tools


def delegation_tools(ctx: TurnContext) -> list[BaseTool]:
    """Background delegation: hand tasks to agents and collect their answers
    later, while doing other work. The synchronous form is the task tool."""

    async def resolve(agent: str, task: str = "") -> teamlib.Member | None:
        members = await teamlib.team(ctx)
        m = teamlib.find(members, agent)
        if m and m.kind == "agent":
            return m
        if ctx.decision is not None:
            # Not one of the space's agents by name (a role, a misspelling):
            # the decision model picks the agent that fits, when it is sure.
            from .decision import routing

            agents = [x for x in members if x.kind == "agent" and x.runtime]
            return await routing.best_agent(ctx.decision, f"Addressed to: {agent}\n{task}", agents)
        return None

    @tool
    async def start_task(agent: str, task: str) -> str:
        """Hand a task to an agent of the space without waiting for it.

        The task is posted in the room addressed to the agent, which starts
        working on it in parallel with you. Returns a task id for check_tasks /
        wait_tasks. Write the task self-contained: goal, inputs (files under
        /workspace), the expected result and where to put it.
        """
        member = await resolve(agent, task)
        if member is None:
            return f"error: no agent named {agent!r} in this space (see list_team, or recruit one)"
        try:
            return f"started task {await teamlib.assign(ctx, member, task)} with {member.name}"
        except GatewayError as exc:
            return _err(exc)

    @tool
    async def check_tasks(task_ids: list[str]) -> str:
        """Check tasks started with start_task: each one's answer, or that it is still running.

        When none has answered yet it waits briefly for the first answer. Do
        not call it in a loop: keep working, or use wait_tasks once.
        """
        deadline = asyncio.get_running_loop().time() + CHECK_WAIT
        while True:
            lines, done = [], False
            for tid in task_ids:
                try:
                    m = await teamlib.answer(ctx, tid)
                except GatewayError as exc:
                    lines.append(f"{tid}: {_err(exc)}")
                    done = True
                    continue
                done = done or m is not None
                lines.append(f"{tid}: running" if m is None else f"{tid}: done\n{_clip(str(m.get('body', '')), 6000)}")
            if done or not task_ids or asyncio.get_running_loop().time() >= deadline:
                break
            await asyncio.sleep(teamlib.POLL_EVERY)
        return "\n\n".join(lines) or "no task ids given"

    @tool
    async def wait_tasks(task_ids: list[str], timeout_seconds: int = 900) -> str:
        """Wait until tasks started with start_task are answered (or the timeout passes) and return the answers."""
        timeout = float(max(10, min(timeout_seconds, int(teamlib.TASK_TIMEOUT))))
        answers = await asyncio.gather(*(teamlib.wait(ctx, tid, timeout) for tid in task_ids), return_exceptions=True)
        return "\n\n".join(f"{tid}:\n{_clip(str(a), 6000)}" for tid, a in zip(task_ids, answers)) or "no task ids given"

    return [start_task, check_tasks, wait_tasks]


def recruit_tool(ctx: TurnContext) -> BaseTool:
    @tool
    async def recruit_agent(name: str, description: str, instructions: str,
                            skills: list[dict[str, str]] | None = None) -> str:
        """Add a new specialist agent to the space when the team lacks one.

        name: short role name (e.g. "data-analyst"). description: one line on
        what it is good at (shown to the team). instructions: its persona, way
        of working and standards. skills: optional [{name, description,
        instructions}] professional skills it loads when relevant.
        The new agent works in the same sandbox and room; give it work with
        start_task (or the task tool from your next turn).
        """
        try:
            out = await ctx.gateway.call("spaces", "agent_recruit", {
                "space": ctx.space, "room": ctx.room, "name": name, "description": description,
                "instructions": instructions, "skills": skills or None,
            })
        except GatewayError as exc:
            return _err(exc)
        return (f"recruited {out.get('name')} (account {out.get('account_id')}, bot {out.get('bot_id')}). "
                f"Hand it work with start_task(agent={out.get('name')!r}, ...).")

    return recruit_agent


async def platform_tools(ctx: TurnContext) -> list[BaseTool]:
    """The space's tool and miniapp bots and the platform tools, over spaces.ask."""
    try:
        listed = await ctx.space_tools()
    except GatewayError:
        return []
    out: list[BaseTool] = []
    used: set[str] = set()
    for t in listed:
        name = t.get("name", "")
        if ctx.turn.no_sandbox and name in {"sandbox_exec", "file_send", "file_upload", "proxy_create", "proxy_list", "proxy_get", "proxy_delete"}:
            continue
        if name in PLATFORM_TOOLS:
            out.append(_platform_tool(ctx, name, PLATFORM_TOOLS[name], t))
            used.add(PLATFORM_TOOLS[name])
        elif t.get("bot_id") and t.get("kind") in ("tool", "miniapp") and name not in ("sandbox_exec",):
            slug = _SLUG.sub("_", name.lower()).strip("_") or "tool"
            commands = [c for c in t.get("commands") or [] if isinstance(c, dict) and c.get("name")]
            if commands:
                # A connected app: each of its functions is a tool of its own,
                # with its own arguments, so the agent calls it like any other.
                for command in commands:
                    tool_name = f"{slug}__{_SLUG.sub('_', str(command['name'])).strip('_')}"[:64]
                    while tool_name in used:
                        tool_name = tool_name[:63] + "_"
                    used.add(tool_name)
                    out.append(_app_command_tool(ctx, tool_name, t, command))
                continue
            tool_name = "ask_" + slug
            while tool_name in used:
                tool_name += "_"
            used.add(tool_name)
            out.append(_bot_tool(ctx, tool_name, t))
    return out


def _app_result(reply: str) -> str:
    """What a connected app answered, as text (its reply is an MCP result)."""
    try:
        result = json.loads(reply)
    except ValueError:
        return reply
    if not isinstance(result, dict):
        return reply
    parts = [str(block.get("text", "")) for block in result.get("content") or []
             if isinstance(block, dict) and block.get("type") == "text"]
    text = "\n".join(p for p in parts if p)
    if not text and result.get("structuredContent") is not None:
        text = json.dumps(result["structuredContent"], ensure_ascii=False)
    if not text:
        text = reply
    return f"The app reported an error: {text}" if result.get("isError") else text


def _app_command_tool(ctx: TurnContext, name: str, spec: dict[str, Any], command: dict[str, Any]) -> BaseTool:
    bot_id = spec["bot_id"]
    function = str(command["name"])
    raw = command.get("schema") if isinstance(command.get("schema"), dict) else {}
    schema = {"type": "object", "properties": raw.get("properties") or {}, "required": raw.get("required") or []}
    description = (str(command.get("description") or "").strip() or f"{function} of {spec.get('name')}.")
    description = f"[{spec.get('name')}] {description}\n{presentation_hint(spec, function)}"

    async def run(**kwargs: Any) -> str:
        try:
            res = await ctx.gateway.call("spaces", "ask", {
                "space": ctx.space, "room": ctx.room, "bot": bot_id,
                "body": json.dumps({"function": function, "payload": {k: v for k, v in kwargs.items() if v is not None}}),
            })
        except GatewayError as exc:
            return _err(exc)
        return _app_result(str(res.get("reply", "")))

    return StructuredTool(name=name, description=description[:2000], args_schema=schema, coroutine=run)


def _platform_tool(ctx: TurnContext, platform_name: str, name: str, spec: dict[str, Any]) -> BaseTool:
    schema = spec.get("parameters") or {"type": "object", "properties": {}}
    schema = {"type": "object", "properties": schema.get("properties", {}), "required": schema.get("required", [])}
    description = spec.get("description", "")
    if spec.get("usage"):
        description += "\n" + spec["usage"]

    async def run(**kwargs: Any) -> str:
        try:
            res = await ctx.gateway.call("spaces", "ask", {
                "space": ctx.space, "room": ctx.room, "tool": platform_name,
                "args": {k: v for k, v in kwargs.items() if v is not None},
            })
        except GatewayError as exc:
            return _err(exc)
        result = res.get("result", res)
        return result if isinstance(result, str) else json.dumps(result)

    return StructuredTool(name=name, description=description[:4000] or name, args_schema=schema, coroutine=run)


def presentation_hint(spec: dict[str, Any], function: str | None = None) -> str:
    """How to show people what this tool returns (see prompts.COMMON)."""
    if spec.get("frontend") or spec.get("commands"):
        call = f"microtool={function!r}, args=<the same arguments>" if function else "microtool=<the function>, args=<its arguments>"
        if spec.get("frontend") == "generative":
            return (f"Show people its result as a card window on the desk, in its own generative frontend: "
                    f"frontend_show(tool={spec['bot_id']!r}, {call}); do not restate the result as text.")
        return (f"Show people its result as a card window on the desk, in an interface designed for their request: "
                f"frontend_show(tool={spec['bot_id']!r}, {call}, request=<what they asked, in their words>); "
                "do not restate the result as text.")
    return "It has no interface to show results in: present its result to people in Markdown."


def _bot_tool(ctx: TurnContext, name: str, spec: dict[str, Any]) -> BaseTool:
    bot_id = spec["bot_id"]
    description = (spec.get("description") or f"The {spec.get('name')} tool of this space.") + (
        "\nSend it a request in natural language or its command syntax; returns its reply.\n" + presentation_hint(spec))

    async def run(request: str) -> str:
        try:
            res = await ctx.gateway.call("spaces", "ask", {
                "space": ctx.space, "room": ctx.room, "bot": bot_id, "body": request,
            })
        except GatewayError as exc:
            return _err(exc)
        return str(res.get("reply", ""))

    return StructuredTool.from_function(coroutine=run, name=name, description=description[:4000])


def filter_allowed(tools: list[BaseTool], allowed: list[str]) -> list[BaseTool]:
    """Restrict platform tools to an agent's allowed_tools (when it has any)."""
    if not allowed:
        return tools
    keep = set(allowed) | CORE_TOOLS | {"recruit_agent"}
    keep |= {PLATFORM_TOOLS[n] for n in allowed if n in PLATFORM_TOOLS}
    return [t for t in tools if t.name in keep]
