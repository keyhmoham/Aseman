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
    "write_todos": "planning", "task": "delegating", "send_message": "messaging the room", "read_room": "reading the room",
    "send_direct_message": "sending a direct message", "ask_user": "asking a question",
    "recruit_agent": "recruiting a specialist", "assemble_team": "setting up the team",
    "run_swarm": "running the team in parallel", "image_generate": "generating an image", "file_send": "sharing a file",
    "codemode_search": "searching capabilities (Code Mode)",
    "codemode_execute": "running Code Mode",
}

_CODEMODE_STATUS = {
    "/platform/file_send": "sharing a file",
    "/platform/file_upload": "uploading a file",
    "/platform/image_generate": "generating an image",
    "/platform/ui_present": "showing an in-chat UI",
    "/platform/appui_create": "building an interactive UI",
    "/platform/proxy_create": "exposing a preview",
    "/timeline/": "reading the project timeline",
    "/apps/": "calling a connected app",
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
    if "code" in args:
        return _clip(str(args["code"]), 400)
    return _clip(json.dumps(args, ensure_ascii=False, default=str), 300)


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


def _codemode_status(args: dict[str, Any]) -> str:
    code = str(args.get("code") or "")
    for path, label in _CODEMODE_STATUS.items():
        if path in code:
            return label
    return "running Code Mode"


def _call_status(call: dict[str, Any]) -> str:
    name = call.get("name", "")
    if name == "codemode_execute":
        return _codemode_status(call.get("args") or {})
    return _STATUS.get(name, f"using {name}")


def _status(calls: list[dict[str, Any]]) -> str:
    """The live status of a step: what its tool calls are doing."""
    shown = list(dict.fromkeys(_call_status(c) for c in calls))
    return ", ".join(shown[:3]) + (" …" if len(shown) > 3 else "") if shown else "thinking…"


class WorkLogMiddleware(AgentMiddleware):
    """Logs every model step and tool call of the agent: one write per step.

    Before a model call the status says it waits for the model; with the
    model's answer, one write logs its reasoning (when it goes on to use tools)
    and sets the status to what those tools do; each tool call then logs what
    it ran and what came of it, in one write.
    """

    def __init__(self, log: WorkLog) -> None:
        super().__init__()
        self.log = log

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        await self.log.write(status="waiting for the model")
        try:
            response = await handler(request)
        except asyncio.CancelledError:
            # The host clears room activity when the cancelled turn unwinds.
            raise
        except Exception as exc:
            await self.log.write(f"Model failed\n{_clip(str(exc), 800)}", status="model request failed")
            raise
        message = next((m for m in reversed(getattr(response, "result", None) or []) if isinstance(m, AIMessage)), None)
        calls = (message.tool_calls or []) if message is not None else []
        thought = message.text.strip() if message is not None and calls else ""
        # The agent's reasoning between steps; its final answer is its reply.
        await self.log.write(f"Thought\n{_clip(thought, 1500)}" if thought else "", status=_status(calls))
        return response

    async def awrap_tool_call(self, request: Any, handler: Any) -> Any:
        call = request.tool_call
        name = call.get("name", "")
        args = call.get("args") or {}
        try:
            result = await handler(request)
        except asyncio.CancelledError:
            # The host clears the room activity as the turn unwinds; do not
            # delay cancellation with another network request here.
            raise
        except Exception as exc:
            await self.log.write(f"Tool failed · {name}\n{_args(args)}\n→ {_clip(str(exc), 800)}")
            raise
        if name == "write_todos":
            todos = args.get("todos") or []
            plan = "\n".join(f"{_TODO_MARK.get(t.get('status', ''), '[ ]')} {t.get('content', '')}" for t in todos)
            await self.log.write(f"Plan\n{plan}")
            return result
        output = result.text if isinstance(result, ToolMessage) else ""
        failed = isinstance(result, ToolMessage) and getattr(result, "status", "") == "error"
        entry = f"{'Tool failed' if failed else 'Tool'} · {name}\n{_args(args)}"
        await self.log.write(entry + (f"\n→ {_clip(output, 1200)}" if output else ""))
        return result
