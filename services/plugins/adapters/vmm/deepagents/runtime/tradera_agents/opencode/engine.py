"""Running an agent's turn on OpenCode.

The OpenCode engine is the agents' backbone: a turn is a message to the
OpenCode session of the agent's thread, and OpenCode runs the agent's loop —
model calls, parallel tool calls, retries, its conversation and compaction,
and the agent's harness (skills, subagents, plugins). Everything that makes a
turn a Tradera turn is the same as on the deepagents engine, because the same
parts provide it (Runner.assemble): the system prompt, memory, the timeline,
the room and the people, every platform and app tool, the shared sandbox, the
swarm. Around OpenCode's loop the runtime keeps:

* the turn's model calls on the node's metered LLM endpoint with its token,
  through the turn guard and the decision model (relay.py, runs.py);
* human in the loop: ``ask_user`` and the agent's ``interrupt_on`` tools pause
  the turn; people's answer (or approval, after which the runtime runs the
  call) is the session's next message;
* a conversation too large for the model's window even after OpenCode's
  compaction: the thread starts a new session, and a turn that has not acted
  yet runs again there;
* the decision model's completion check, once a turn;
* the work log, live status and the room's draft of the answer;
* the agent's harness improving as it works (harness/).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from typing import Any, Callable, Literal

from langchain_core.messages import HumanMessage
from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field

from .. import economy, guard as guardlib, subagents
from ..context import TurnContext
from ..decision import completion
from ..gateway import GatewayError
from ..store import Question, Store
from . import convert
from .runs import NOTE, STOPPED_REPLY, Registry, TurnRun
from .server import OpenCodeError, OpenCodeServer
from .workspace import HarnessFiles, Projects, compaction_limit, project_key, window

log = logging.getLogger("tradera.agents.opencode")

_OVERFLOW = ("context_length_exceeded", "context length", "context window", "maximum context", "prompt is too long",
             "too many input tokens", "exceeds model limit", "context limit")


class Todo(BaseModel):
    content: str = Field(description="The step.")
    status: Literal["pending", "in_progress", "completed"] = Field(description="Where the step is.")


def planning_tool(ctx: TurnContext, store: Store) -> BaseTool:
    """``write_todos`` on the OpenCode engine (the deepagents engine's own
    schema and wording); the plan is kept per thread."""

    @tool(description=economy.TODO_TOOL)
    async def write_todos(todos: list[Todo]) -> str:
        clean = [{"content": t.content, "status": t.status} for t in todos if t.content.strip()]
        store.put_todos(ctx.thread_id, clean)
        marks = {"completed": "[x]", "in_progress": "[~]", "pending": "[ ]"}
        return "Plan updated:\n" + "\n".join(f"{marks.get(t['status'], '[ ]')} {t['content']}" for t in clean)

    return write_todos


def sandbox_tools(backend: Any) -> tuple[list[BaseTool], Any]:
    """The shared sandbox's shell and files: the deepagents engine's own tools."""
    from deepagents.middleware.filesystem import FilesystemMiddleware

    fs = FilesystemMiddleware(backend=backend, custom_tool_descriptions=economy.FILE_TOOLS,
                              tool_token_limit_before_evict=economy.RESULT_TO_FILE_ABOVE)
    return list(fs.tools), fs


async def skills_section(backend: Any, sources: list[str]) -> str:
    """The sandbox's skills, listed as the deepagents engine lists them."""
    if backend is None or not sources:
        return ""
    from deepagents.middleware.skills import SkillsMiddleware

    mw = SkillsMiddleware(backend=backend, sources=sources, system_prompt=economy.SKILLS_PROMPT)
    try:
        loaded = await mw.abefore_agent({}, None, {}) or {}
    except Exception as exc:  # noqa: BLE001 - the turn goes on without the list
        log.warning("skills unavailable: %s", exc)
        return ""
    return economy.SKILLS_PROMPT.format(skills_locations=mw._format_skills_locations(),
                                        skills_load_warnings=mw._format_skills_load_warnings(loaded.get("skills_load_errors") or []),
                                        skills_list=mw._format_skills_list(loaded.get("skills_metadata") or []))


def parts_of(payload: Any) -> list[dict[str, Any]]:
    """A turn's input (Runner._input) as OpenCode message parts."""
    messages = payload.get("messages") if isinstance(payload, dict) else None
    message = messages[-1] if messages else HumanMessage(content=str(payload))
    content = message.content
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    parts: list[dict[str, Any]] = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append({"type": "text", "text": block.get("text", "")})
        elif isinstance(block, dict) and block.get("type") == "image_url":
            url = (block.get("image_url") or {}).get("url", "")
            mime = url[5:].split(";")[0] if url.startswith("data:") else "image/jpeg"
            parts.append({"type": "file", "mime": mime, "url": url, "filename": "attachment"})
    return parts or [{"type": "text", "text": ""}]


def final_text(parts: list[dict[str, Any]]) -> str:
    return "".join(p.get("text", "") for p in parts if p.get("type") == "text" and not p.get("synthetic")).strip()


def is_overflow(error: dict[str, Any]) -> bool:
    name = str(error.get("name", ""))
    text = json.dumps(error.get("data") or {}).lower()
    return name == "ContextOverflowError" or (any(m in text for m in _OVERFLOW) and "rate limit" not in text)


class OpenCodeEngine:
    """Runs turns on an OpenCode server (one per runtime)."""

    def __init__(self, server: OpenCodeServer, registry: Registry, projects: Projects, *,
                 harness: Any = None) -> None:
        self.server = server
        self.registry = registry
        self.projects = projects
        self.harness = harness  # harness.Harness: the agents' self-improvement, or None
        self._listed: dict[str, str] = {}

    async def start(self) -> None:
        await self.server.start()

    async def stop(self) -> None:
        if self.harness is not None:
            await self.harness.drain()
        await self.server.stop()

    # --- a turn -------------------------------------------------------------------

    async def _turn(self, runner: Any, ctx: TurnContext) -> TurnRun:
        kit = await runner.assemble(ctx)
        tools = list(kit.tools)
        fs = None
        if kit.backend is not None:
            fs_tools, fs = sandbox_tools(kit.backend)
            tools = fs_tools + tools
        tools.append(subagents.task_tool(await subagents.subagents(ctx, kit.members)))
        tools.append(planning_tool(ctx, runner.store))
        system = kit.system + "\n\n" + economy.TODO_PROMPT
        if kit.notes is not None:
            from ..memory import MEMORY_PROMPT, notes_block

            system += "\n\n" + MEMORY_PROMPT.format(notes=notes_block(kit.notes))
        skills = await skills_section(kit.backend, kit.skills)
        if skills:
            system += "\n\n" + skills
        decision = ctx.decision_config
        gated = {n for n in kit.interrupt_on if n != "ask_user"}
        return TurnRun(key=project_key(ctx.base_thread), ctx=ctx, tools={t.name: t for t in tools}, system=system,
                       guard=guardlib.TurnGuard(guardlib.max_calls(ctx.agent.max_turns)), gated=gated,
                       approvable=gated if decision and decision.auto_approve else set(), fs=fs, store=runner.store,
                       agents=[m for m in kit.members if m.kind == "agent" and m.runtime])

    async def run(self, runner: Any, ctx: TurnContext, payload: Any, *, fresh_retry: bool = True) -> Any:
        log.info("turn %s agent=%s space=%s room=%s (opencode)", ctx.thread_id, ctx.agent.name, ctx.space, ctx.room)
        try:
            run = await self._turn(runner, ctx)
        except GatewayError as exc:
            return runner_outcome(reply="", status="failed", error=str(exc))
        return await self._drive(runner, ctx, run, parts_of(payload), fresh_retry=fresh_retry,
                                 retry_input=lambda: runner._input(ctx))

    async def resume(self, runner: Any, ctx: TurnContext, pending: Question, answer: str, *, approve: bool) -> Any:
        try:
            run = await self._turn(runner, ctx)
        except GatewayError as exc:
            return runner_outcome(reply="", status="failed", error=str(exc))
        lines: list[str] = []
        for action in pending.actions or [{"name": "ask_user"}]:
            name, args = action.get("name", ""), action.get("args") or {}
            if name == "ask_user":
                lines.append(answer)
            elif approve and name in run.tools:
                blocks, failed = await run.run_tool(name, args, f"approved-{pending.id}")
                result = "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")
                lines.append(f"Approved ({answer}). `{name}` ran with {json.dumps(args, ensure_ascii=False)[:600]}"
                             f" and {'failed' if failed else 'returned'}:\n{result[:6000]}")
            else:
                lines.append(f"Not approved. `{name}` did not run. {answer}")
        return await self._drive(runner, ctx, run, [{"type": "text", "text": "\n\n".join(lines)}], fresh_retry=False)

    async def _drive(self, runner: Any, ctx: TurnContext, run: TurnRun, parts: list[dict[str, Any]], *,
                     fresh_retry: bool, retry_input: Callable[[], Any] | None = None) -> Any:
        harness = await self._harness_view(ctx)
        files = harness.files if harness is not None else HarnessFiles()
        if harness is not None and harness.always_on:
            run.system += "\n\n" + harness.always_on
        directory, changed = self.projects.ensure(run.key, ctx.agent, steps=run.guard.budget + 10, harness=files,
                                                  plugins=bool(harness and harness.plugins_enabled))
        if changed:
            await self.server.dispose(directory)
        self.registry.add(run)
        try:
            outcome, observe = await self._loop(runner, ctx, run, directory, parts, fresh_retry, retry_input)
        finally:
            self.registry.remove(run)
        if harness is not None and observe:
            # How the turn went (a failed one most of all) is what the agent's harness learns from.
            try:
                await self.harness.observe(ctx, run, outcome, harness)
            except Exception:  # noqa: BLE001 - learning never fails a turn
                log.exception("harness observation failed")
        return outcome

    async def _loop(self, runner: Any, ctx: TurnContext, run: TurnRun, directory: str, parts: list[dict[str, Any]],
                    fresh_retry: bool, retry_input: Callable[[], Any] | None) -> tuple[Any, bool]:
        """OpenCode's loop on the turn: its outcome, and whether the harness
        learns from it (not from a turn handed on to a fresh conversation)."""
        session = ""
        try:
            await self._connect(directory, run)
            session = await self._session(runner.store, ctx, directory)
            run.root_session = session
            await self._compact(ctx, directory, session)
            run.on_stop = lambda: self.server.abort(directory, session)
            out = await self.server.prompt(directory, session, parts=parts, system=run.system)
            if run.stopped:
                # The turn ran past its budget and OpenCode was stopped: what it got done.
                text = await self._progress(runner, ctx, directory, session)
                return runner._record(ctx, runner_outcome(reply=f"{text}\n\n{STOPPED_REPLY}".strip())), True
            error = (out.get("info") or {}).get("error")
            if isinstance(error, dict) and error:
                if is_overflow(error):
                    return await self._overflowed(runner, ctx, run, directory, session, error, fresh_retry,
                                                  retry_input), False
                if run.paused:
                    return runner._record(ctx, runner._awaiting(ctx, [{"action_requests": run.actions}])), True
                # The node's own words for a failed model call (relay.py), else OpenCode's.
                message = run.failure or str((error.get("data") or {}).get("message") or error.get("name")
                                             or "the agent's run failed")
                return runner_outcome(reply=await self._progress(runner, ctx, directory, session), status="failed",
                                      error=message), True
            if run.paused:
                return runner._record(ctx, runner._awaiting(ctx, [{"action_requests": run.actions}])), True
            text = final_text(out.get("parts") or []) or await self._last_text(directory, session)
            if text and await run.incomplete(ctx.turn.message, text):
                await run.worklog.write("Decision · completion check: the answer does not deliver the request yet; "
                                        "continuing")
                again = await self.server.prompt(directory, session, system=run.system,
                                                 parts=[{"type": "text", "text": NOTE + completion.NOTE}])
                if run.paused:
                    return runner._record(ctx, runner._awaiting(ctx, [{"action_requests": run.actions}])), True
                if not (again.get("info") or {}).get("error"):
                    text = final_text(again.get("parts") or []) or text
            runner.store.drop_question(ctx.thread_id)
            return runner._record(ctx, runner_outcome(reply=text)), True
        except asyncio.CancelledError:
            if session:
                await asyncio.shield(self.server.abort(directory, session))
            raise
        except OpenCodeError as exc:
            log.exception("opencode turn failed")
            return runner_outcome(reply="", status="failed", error=f"OpenCode: {exc}"), True

    async def _harness_view(self, ctx: TurnContext) -> Any:
        if self.harness is None:
            return None
        try:
            return await self.harness.view(ctx)
        except Exception:  # noqa: BLE001 - the turn runs with no harness rather than fail
            log.exception("harness unavailable for %s", ctx.agent.name)
            return None

    async def _connect(self, directory: str, run: TurnRun) -> None:
        """OpenCode lists a project's tools when it connects: reconnect when the
        turn's tools are not the ones it listed."""
        digest = hashlib.sha256(json.dumps(run.tool_specs(), sort_keys=True, default=str).encode()).hexdigest()
        status = await self.server.mcp_status(directory)
        connected = (status.get(convert.MCP_SERVER) or {}).get("status") == "connected"
        if not connected or self._listed.get(run.key) not in (None, digest):
            await self.server.mcp_reconnect(directory, convert.MCP_SERVER)
        self._listed[run.key] = digest

    async def _session(self, store: Store, ctx: TurnContext, directory: str) -> str:
        sid = store.session(ctx.thread_id)
        if sid and await self.server.session_exists(directory, sid):
            return sid
        title = f"{ctx.agent.name} · {ctx.space}/{ctx.room}" + (f" · task {ctx.turn.instance}" if ctx.turn.instance else "")
        sid = await self.server.create_session(directory, title)
        store.put_session(ctx.thread_id, sid)
        return sid

    async def _compact(self, ctx: TurnContext, directory: str, session: str) -> None:
        """Compact the session before the turn when its last call carried more
        than the deepagents engine let a conversation grow to: the turn starts
        from a summary instead of the whole history."""
        limit = compaction_limit(window(ctx.agent))
        try:
            messages = await self.server.messages(directory, session)
        except OpenCodeError:
            return
        for m in reversed(messages):
            info = m.get("info") or {}
            if info.get("role") != "assistant" or info.get("summary"):
                if info.get("summary"):
                    return  # already compacted since
                continue
            tokens = info.get("tokens") or {}
            used = int(tokens.get("input") or 0) + int((tokens.get("cache") or {}).get("read") or 0) + \
                int(tokens.get("output") or 0)
            if not used:
                continue  # an answer the runtime gave itself (a pause, a stop): no measure of the context
            if used > limit:
                log.info("compacting %s for %s (%d tokens > %d)", session, ctx.agent.name, used, limit)
                await self.server.summarize(directory, session)
            return

    async def _last_text(self, directory: str, session: str) -> str:
        """The agent's last words since the message it answers."""
        try:
            messages = await self.server.messages(directory, session)
        except OpenCodeError:
            return ""
        for m in reversed(messages):
            role = (m.get("info") or {}).get("role")
            if role == "user":
                break
            text = final_text(m.get("parts") or [])
            if role == "assistant" and text:
                return text
        return ""

    async def _progress(self, runner: Any, ctx: TurnContext, directory: str, session: str) -> str:
        """What a turn that could not finish got done: its last words and plan."""
        parts = []
        text = await self._last_text(directory, session) if session else ""
        if text:
            parts.append(text)
        todos = runner.store.todos(ctx.thread_id)
        if todos:
            marks = {"completed": "[x]", "in_progress": "[~]", "pending": "[ ]"}
            parts.append("Progress:\n" + "\n".join(f"- {marks.get(t.get('status', ''), '[ ]')} {t.get('content', '')}"
                                                   for t in todos))
        return "\n\n".join(parts)

    async def _overflowed(self, runner: Any, ctx: TurnContext, run: TurnRun, directory: str, session: str,
                          error: dict[str, Any], fresh_retry: bool, retry_input: Callable[[], Any] | None) -> Any:
        """The conversation no longer fits the model's window even after
        OpenCode's compaction: the thread starts a new session (it catches up
        on the room); a turn that has not acted yet runs again there at once."""
        old = ctx.thread_id
        reply = await self._progress(runner, ctx, directory, session)
        ctx.generation = runner.store.next_generation(ctx.base_thread)
        runner.store.drop_question(old)
        log.warning("turn %s overflowed the model's window (%s); thread continues as %s", old, error, ctx.thread_id)
        if fresh_retry and not run.acted and retry_input is not None:
            fresh = await self._turn(runner, ctx)
            return await self._drive(runner, ctx, fresh, parts_of(await retry_input()), fresh_retry=False)
        note = ("My working memory for this room was full, so I have started a fresh one; I still see the room's "
                "recent messages. Please ask again if anything is left to do.")
        return runner_outcome(reply=f"{reply}\n\n{note}".strip(), status="failed",
                              error=f"ContextOverflowError: {(error.get('data') or {}).get('message', '')}")


def runner_outcome(**kwargs: Any) -> Any:
    from ..agent import Outcome

    return Outcome(**kwargs)
