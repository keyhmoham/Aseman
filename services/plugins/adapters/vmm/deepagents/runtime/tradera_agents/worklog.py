"""An agent's work log: what it plans, runs and finds, as it happens.

Every step is written through ``spaces.agent_log``: the one-line live status
people see while the agent works, and log entries in the room that stay as
the history of its run.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage, ToolMessage

from .context import TurnContext

_STATUS = {
    "execute": "running a command in the sandbox",
    "ls": "browsing files", "read_file": "reading files", "glob": "searching files", "grep": "searching files",
    "write_file": "writing files", "edit_file": "editing files",
    "write_todos": "planning", "task": "delegating", "start_task": "delegating", "wait_tasks": "waiting on the team",
    "check_tasks": "checking on the team", "send_message": "messaging the room", "read_room": "reading the room",
    "send_direct_message": "sending a direct message", "ask_user": "asking a question",
    "recruit_agent": "recruiting a specialist", "image_generate": "generating an image", "file_send": "sharing a file",
}

_TODO_MARK = {"completed": "[x]", "in_progress": "[~]", "pending": "[ ]"}


def _clip(text: str, n: int) -> str:
    text = text.strip()
    return text if len(text) <= n else text[:n] + "…"


def _args(args: dict[str, Any]) -> str:
    if "command" in args:
        return _clip(str(args["command"]), 400)
    if "file_path" in args or "path" in args:
        return str(args.get("file_path") or args.get("path"))
    if "subagent_type" in args:
        return f"{args['subagent_type']}: {_clip(str(args.get('description', '')), 300)}"
    return _clip(json.dumps(args, ensure_ascii=False, default=str), 300)


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content)
    return str(content)


class WorkLog:
    """Writes one agent's work log entries and status for a turn."""

    def __init__(self, ctx: TurnContext) -> None:
        self.ctx = ctx

    async def write(self, text: str = "", status: str | None = None) -> None:
        body: dict[str, Any] = {"space": self.ctx.space, "room": self.ctx.room}
        if text:
            body["text"] = text
        if status is not None:
            body["status"] = status
        try:
            # A live-status write must never be what stalls the work it describes.
            await asyncio.wait_for(self.ctx.gateway.call("spaces", "agent_log", body), timeout=10.0)
        except Exception:  # noqa: BLE001 - status/logging is deliberately best effort
            pass  # the log is best effort; the work goes on


class WorkLogMiddleware(AgentMiddleware):
    """Logs every model step and tool call of the agent."""

    def __init__(self, log: WorkLog) -> None:
        super().__init__()
        self.log = log

    async def aafter_model(self, state: Any, runtime: Any) -> dict[str, Any] | None:
        messages = state.get("messages") or []
        if not messages or not isinstance(messages[-1], AIMessage):
            return None
        msg = messages[-1]
        thought = _text(msg.content).strip()
        if thought and msg.tool_calls:
            # The agent's reasoning between steps; its final answer is its reply.
            await self.log.write(f"Thought\n{_clip(thought, 1500)}")
        return None

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        """Keep the visible status accurate and persist provider failures."""
        await self.log.write(status="waiting for the model")
        try:
            response = await handler(request)
        except asyncio.CancelledError:
            # The host clears room activity when the cancelled turn unwinds.
            raise
        except Exception as exc:
            await self.log.write(f"Model failed\n{_clip(str(exc), 800)}", status="model request failed")
            raise
        await self.log.write(status="thinking…")
        return response

    async def awrap_tool_call(self, request: Any, handler: Any) -> Any:
        call = request.tool_call
        name = call.get("name", "")
        args = call.get("args") or {}
        await self.log.write(status=_STATUS.get(name, f"using {name}"))
        try:
            result = await handler(request)
        except asyncio.CancelledError:
            # The host clears the room activity as the turn unwinds; do not
            # delay cancellation with another network request here.
            raise
        except Exception as exc:
            await self.log.write(f"Tool failed · {name}\n{_args(args)}\n→ {_clip(str(exc), 800)}")
            await self.log.write(status="thinking…")
            raise
        output = _text(result.content) if isinstance(result, ToolMessage) else ""
        failed = isinstance(result, ToolMessage) and getattr(result, "status", "") == "error"
        if name == "write_todos":
            todos = args.get("todos") or []
            plan = "\n".join(f"{_TODO_MARK.get(t.get('status', ''), '[ ]')} {t.get('content', '')}" for t in todos)
            await self.log.write(f"Plan\n{plan}")
        else:
            entry = f"{'Tool failed' if failed else 'Tool'} · {name}\n{_args(args)}"
            if output:
                entry += f"\n→ {_clip(output, 1200)}"
            await self.log.write(entry)
        await self.log.write(status="thinking…")
        return result
