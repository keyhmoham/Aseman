"""What the runtime knows about each OpenCode project while it works.

A run is registered under its project's key for as long as OpenCode works on
it, and the relay (relay.py) and the MCP server (mcp.py) find it by that key:

* a ``TurnRun`` is an agent's turn. Its tools are the turn's tools (the very
  LangChain tools of the deepagents engine, the sandbox's file tools among
  them), run here and written to the work log; ``ask_user`` and the agent's
  ``interrupt_on`` tools pause it for people. Every model call passes its turn
  guard and, when the admin turned one on, its decision model, and goes to
  the node's metered LLM endpoint with the turn's token.
* an ``EditorRun`` is a harness editor's session (harness/editor.py): OpenCode's
  own file tools in a scratch directory, its model calls billed as the
  agent's learning (the node's learn endpoint).
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import inspect
import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any

from langchain_core.messages import AIMessage, ToolMessage

from .. import guard as guardlib
from ..context import TurnContext
from ..decision import approval, completion, progress, routing
from ..decision import tools as choosing
from ..decision.middleware import DELIVERY_TOOLS, last_request
from ..worklog import WorkLog, _STATUS, _TODO_MARK, _args, _clip
from . import convert, diet

log = logging.getLogger("tradera.agents.opencode")

NOTE = guardlib.NOTE
#: The agent's own OpenCode agent (workspace.py); OpenCode's others are its own work.
AGENT = "tradera"
#: What a paused turn's model is answered with (it is not shown to anyone).
PAUSED_REPLY = "(waiting for people to answer)"
#: Model calls past the budget, or compactions in one turn, after which the turn is ended.
OVERRUN = 3
MAX_COMPACTIONS = 3
#: A tool result kept whole when there is no sandbox to put the rest in (characters).
NO_SANDBOX_MAX_CHARS = 40_000
STOPPED_REPLY = ("I ran out of steps for this turn before finishing. Ask me to continue and I will pick up "
                 "where I left off.")

ASKED = ("Your question is posted in the room and your work pauses until a person answers. End your turn now "
         "without another tool call; the answer arrives as the next message.")
NEEDS_APPROVAL = ("This call needs a person's approval and has NOT run yet. End your turn now without another tool "
                  "call; you will be told whether it was approved (and what it returned) in the next message.")
AFTER_PAUSE = "Your turn is waiting for people. Do not call more tools: end your turn now."


def key_token(secret: str, key: str) -> str:
    """The credential of one project's relay and MCP endpoints."""
    return hmac.new(secret.encode(), key.encode(), hashlib.sha256).hexdigest()


class Run:
    """A project OpenCode is working on right now (subclasses set ``key`` and
    ``root_session``, the session the run's own prompt goes to)."""

    #: The node's own words for the last model call that failed (relay.py).
    failure = ""

    #: Whether the model sees tools under the agent's names (convert.py), or as OpenCode names them.
    translate = True

    def upstream(self) -> tuple[str, dict[str, str]]:
        """Where its model calls go: (chat completions URL, headers)."""
        raise NotImplementedError

    def http(self) -> Any:
        """The HTTP client its model calls go out on."""
        raise NotImplementedError

    async def prepare(self, body: dict[str, Any], session: str, agent: str = "") -> dict[str, Any] | str:
        """The model request to send, or the text to answer it with right away."""
        return body

    async def model_started(self) -> None:
        pass

    async def model_finished(self, message: dict[str, Any] | None, error: str = "") -> None:
        pass

    def tool_specs(self) -> list[dict[str, Any]]:
        return []

    async def call_tool(self, name: str, args: dict[str, Any], call_id: str) -> tuple[list[dict[str, Any]], bool]:
        return [{"type": "text", "text": f"error: no tool named {name}"}], True


class Registry:
    """Runs by key; and the tools each key last listed, for OpenCode reconnecting between turns."""

    def __init__(self, secret: str) -> None:
        self.secret = secret
        self._runs: dict[str, Run] = {}
        self._specs: dict[str, list[dict[str, Any]]] = {}

    def token(self, key: str) -> str:
        return key_token(self.secret, key)

    def authorized(self, key: str, header: str) -> bool:
        given = header.removeprefix("Bearer ").strip()
        return bool(given) and hmac.compare_digest(given, self.token(key))

    def add(self, run: Run) -> None:
        self._runs[run.key] = run
        self._specs[run.key] = run.tool_specs()

    def remove(self, run: Run) -> None:
        if self._runs.get(run.key) is run:
            del self._runs[run.key]

    def get(self, key: str) -> Run | None:
        return self._runs.get(key)

    def specs(self, key: str) -> list[dict[str, Any]]:
        run = self._runs.get(key)
        return run.tool_specs() if run is not None else self._specs.get(key, [])


# --- a turn's tools ----------------------------------------------------------------


def schema_of(tool: Any) -> dict[str, Any]:
    """A LangChain tool's arguments as the model sees them on the deepagents
    engine: LangChain's own conversion (references resolved, titles dropped,
    injected arguments left out)."""
    from langchain_core.utils.function_calling import convert_to_openai_tool

    try:
        schema = dict(convert_to_openai_tool(tool)["function"].get("parameters") or {})
    except Exception:  # noqa: BLE001 - a tool whose schema cannot be converted takes free-form arguments
        schema = {}
    schema["type"] = "object"
    schema.setdefault("properties", {})
    return schema


def _needs_runtime(tool: Any) -> bool:
    fn = getattr(tool, "coroutine", None) or getattr(tool, "func", None)
    try:
        return fn is not None and "runtime" in inspect.signature(fn).parameters
    except (TypeError, ValueError):
        return False


def _blocks(content: Any) -> list[dict[str, Any]]:
    """A tool result as MCP content."""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        out: list[dict[str, Any]] = []
        for b in content:
            if isinstance(b, str):
                out.append({"type": "text", "text": b})
            elif isinstance(b, dict) and b.get("type") == "text":
                out.append({"type": "text", "text": str(b.get("text", ""))})
            elif isinstance(b, dict) and b.get("type") in ("image", "image_url"):
                url = b.get("url") or (b.get("image_url") or {}).get("url") or ""
                data, mime = b.get("base64") or b.get("data"), b.get("mime_type") or b.get("mimeType")
                if not data and isinstance(url, str) and url.startswith("data:"):
                    head, _, data = url.partition(",")
                    mime = head[5:].split(";")[0]
                if data:
                    out.append({"type": "image", "data": data, "mimeType": mime or "image/png"})
                elif url:
                    out.append({"type": "text", "text": f"[image: {url}]"})
            else:
                out.append({"type": "text", "text": json.dumps(b, default=str)[:4000]})
        return out or [{"type": "text", "text": ""}]
    if content is None:
        return [{"type": "text", "text": ""}]
    return [{"type": "text", "text": content if isinstance(content, str) else json.dumps(content, default=str)}]


def _text(blocks: list[dict[str, Any]]) -> str:
    return "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")


@dataclass
class TurnRun(Run):
    """An agent's turn while OpenCode works on it."""

    key: str
    ctx: TurnContext
    tools: dict[str, Any]
    system: str
    guard: guardlib.TurnGuard
    gated: set[str] = field(default_factory=set)
    approvable: set[str] = field(default_factory=set)
    fs: Any = None  # the sandbox's FilesystemMiddleware: large results go to a file
    store: Any = None
    agents: list[Any] = field(default_factory=list)  # for the decision model's routing hint
    root_session: str = ""
    # Filled as the turn goes.
    paused: bool = False
    actions: list[dict[str, Any]] = field(default_factory=list)  # what waits on people, in order
    acted: bool = False
    delivered: list[str] = field(default_factory=list)
    trajectory: list[dict[str, Any]] = field(default_factory=list)  # for the harness (harness/)
    compactions: int = 0
    stopped: bool = False
    # Called when the turn is stopped (engine.py aborts OpenCode's loop).
    on_stop: Any = None
    _chosen: set[str] | None = None
    _hint: str = ""
    _decided: bool = False
    _calls: int = 0

    def __post_init__(self) -> None:
        self.worklog = WorkLog(self.ctx)

    # --- the model side (relay.py) ---------------------------------------------

    def upstream(self) -> tuple[str, dict[str, str]]:
        return (self.ctx.gateway.llm_base_url + "/chat/completions",
                {"Authorization": f"Bearer {self.ctx.gateway.token}"})

    def http(self) -> Any:
        return self.ctx.gateway.http

    async def prepare(self, body: dict[str, Any], session: str, agent: str = "") -> dict[str, Any] | str:
        if self.paused:
            return PAUSED_REPLY
        body = convert.model_request(body)
        messages = list(body.get("messages") or [])
        # The agent's own calls (its OpenCode agent on its own session) get its
        # prompt, guard, decision model and context diet. OpenCode's own work
        # on the session (compacting it) and harness subagents keep their
        # prompts: replacing a compaction's prompt with the agent's turned the
        # summary into one more answer, and the agent lost its history.
        own = agent == AGENT if agent else (not session or session == self.root_session)
        if agent == "compaction":
            self.compactions += 1
        if messages and messages[0].get("role") == "system":
            content = self.system if own else convert.strip_env(convert.text_of(messages[0].get("content")))
            messages[0] = {"role": "system", "content": content}
        elif own:
            messages.insert(0, {"role": "system", "content": self.system})
        tools = list(body.get("tools") or [])
        if own:
            self.guard.calls += 1
            self._calls += 1
            if self.stopped or self.guard.calls > self.guard.budget + OVERRUN or self.compactions > MAX_COMPACTIONS:
                # The model was told to finish and OpenCode still goes on: end
                # its loop rather than let it run on.
                if not self.stopped:
                    self.stopped = True
                    log.warning("turn %s stopped: %d model calls, %d compactions", self.key, self.guard.calls,
                                self.compactions)
                    if self.on_stop is not None:
                        asyncio.get_running_loop().create_task(self.on_stop())
                return STOPPED_REPLY
            # The guard and the decision model read the whole conversation; the model gets it on its diet.
            lc = convert.to_langchain(messages)
            messages = diet.trim(messages)
            tools, notes = await self._decide(lc, tools)
            if self.guard.exhausted:
                notes.append("This turn has used all its steps: no more tools can run. Write your final answer "
                             "now: what you did, the results and where they are, and what is left to do.")
                tools = []
            else:
                notes += guardlib.notes(lc, self.guard.calls, self.guard.budget)
            if notes:
                messages.append(convert.note_message(NOTE + "\n".join(notes)))
        body["messages"] = messages
        if tools:
            body["tools"] = tools
        else:
            body.pop("tools", None)
            body.pop("tool_choice", None)
            body.pop("parallel_tool_calls", None)
        definition = self.ctx.agent
        # The node picks the provider and model of the agent; its own output
        # limit applies unless the agent sets one.
        body["model"] = definition.model or "default"
        body.pop("max_tokens", None)
        body.pop("max_completion_tokens", None)
        if definition.max_tokens:
            body["max_tokens"] = definition.max_tokens
        if definition.reasoning_effort and own:
            body["reasoning_effort"] = definition.reasoning_effort
        if os.environ.get("TRADERA_STREAM", "1") == "0":
            body["stream"] = False
            body.pop("stream_options", None)
        return body

    async def _decide(self, lc: list[Any], tools: list[Any]) -> tuple[list[Any], list[str]]:
        """The decision model on a model call (decision/middleware.py, over the relay)."""
        decision = self.ctx.decision
        if decision is None:
            return tools, []
        request = last_request(lc)
        if not self._decided:
            self._decided = True
            chosen, hint = await asyncio.gather(
                choosing.shortlist(decision, request, tools),
                routing.lead_hint(decision, request, self.agents) if self.ctx.agent.lead else _nothing())
            self._chosen, self._hint = chosen, hint or ""
        notes: list[str] = []
        shown = tools
        if self._chosen is not None:
            used = {c.get("name") for m in lc if isinstance(m, AIMessage) for c in m.tool_calls or []}
            keep = choosing.PINNED | self._chosen | used | set(convert.BUILTINS.values())
            shown = [t for t in tools if choosing.tool_name(t) in keep]
            hidden = [choosing.tool_name(t) for t in tools if choosing.tool_name(t) not in keep]
            if hidden:
                notes.append(choosing.hidden_note(hidden))
        if self._hint:
            notes.append(self._hint)
        steps = progress.recent_steps(lc)
        if decision.enabled and progress.due(self._calls, len(steps)) and await progress.stuck(decision, request, steps):
            notes.append(progress.NOTE)
            await self.worklog.write("Decision · progress check: the latest steps are not moving the work forward")
        return shown, notes

    async def model_started(self) -> None:
        await self.worklog.write(status="waiting for the model")

    async def model_finished(self, message: dict[str, Any] | None, error: str = "") -> None:
        if error:
            await self.worklog.write(f"Model failed\n{_clip(error, 800)}", status="model request failed")
            return
        if message:
            thought = convert.text_of(message.get("content")).strip()
            if thought and message.get("tool_calls"):
                # The agent's reasoning between steps; its final answer is its reply.
                await self.worklog.write(f"Thought\n{_clip(thought, 1500)}")
            self.trajectory.append({"type": "text", "text": thought} if thought else {"type": "step"})
        await self.worklog.write(status="thinking…")

    # --- the tool side (mcp.py) -------------------------------------------------

    def tool_specs(self) -> list[dict[str, Any]]:
        return [{"name": name, "description": (getattr(t, "description", "") or name)[:4000],
                 "inputSchema": schema_of(t)} for name, t in self.tools.items()]

    def pause(self, name: str, args: dict[str, Any]) -> None:
        self.paused = True
        self.actions.append({"name": name, "args": args})

    async def call_tool(self, name: str, args: dict[str, Any], call_id: str) -> tuple[list[dict[str, Any]], bool]:
        if self.paused:
            return _blocks(AFTER_PAUSE), True
        tool = self.tools.get(name)
        if tool is None:
            return _blocks(f"error: no tool named {name}"), True
        if name == "ask_user":
            self.pause(name, args)
            await self.worklog.write(status="asking a question")
            return _blocks(ASKED), False
        if name in self.gated:
            if not await self._approved(name, args):
                self.pause(name, args)
                await self.worklog.write(status="waiting for approval")
                return _blocks(NEEDS_APPROVAL), False
        return await self.run_tool(name, args, call_id)

    async def _approved(self, name: str, args: dict[str, Any]) -> bool:
        """The decision model approves a low-risk call when the admin allows it."""
        if name not in self.approvable or self.ctx.decision is None or not self.ctx.decision.enabled:
            return False
        ids = await approval.approve(self.ctx.decision, self.ctx.turn.message, [{"id": "c", "name": name, "args": args}])
        if ids:
            await self.worklog.write(f"Decision · auto-approved as low risk: {name}")
        return bool(ids)

    async def run_tool(self, name: str, args: dict[str, Any], call_id: str) -> tuple[list[dict[str, Any]], bool]:
        """Run one of the turn's tools, as the deepagents engine's work log shows it."""
        tool = self.tools[name]
        await self.worklog.write(status=_STATUS.get(name, f"using {name}"))
        failed = False
        try:
            if _needs_runtime(tool):
                from langchain.tools import ToolRuntime

                runtime = ToolRuntime(state={"messages": [], "files": {}}, context=None, config={},
                                      stream_writer=lambda *_: None, tool_call_id=call_id, store=None)
                validated = tool.args_schema.model_validate(args).model_dump(exclude_none=True) \
                    if hasattr(tool.args_schema, "model_validate") else args
                validated.pop("runtime", None)
                result = await tool.coroutine(runtime=runtime, **validated)
            else:
                result = await tool.ainvoke(args)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - the model reads the error
            await self.worklog.write(f"Tool failed · {name}\n{_args(args)}\n→ {_clip(str(exc), 800)}")
            await self.worklog.write(status="thinking…")
            self.trajectory.append({"type": "tool", "tool": name, "state": {"status": "error", "input": args, "error": str(exc)}})
            return _blocks(f"error: {type(exc).__name__}: {exc}"), True
        if hasattr(result, "update") and not isinstance(result, ToolMessage):  # a Command
            msgs = [m for m in (getattr(result, "update", None) or {}).get("messages", []) if isinstance(m, ToolMessage)]
            result = msgs[-1] if msgs else str(getattr(result, "update", ""))
        if isinstance(result, ToolMessage):
            failed = getattr(result, "status", "") == "error"
            if self.fs is not None:
                try:
                    result, _ = await self.fs._aprocess_large_message(result, self.fs.backend)
                except Exception:  # noqa: BLE001 - shown whole instead
                    pass
            content = result.content
        else:
            content = result
            if self.fs is None and isinstance(content, str) and len(content) > NO_SANDBOX_MAX_CHARS:
                # Nowhere to put it: the start of it, as the deepagents engine's truncation would.
                content = content[:NO_SANDBOX_MAX_CHARS] + f"\n… [{len(content) - NO_SANDBOX_MAX_CHARS} more characters cut]"
            if self.fs is not None and isinstance(content, str) and len(content) > 6000:
                try:
                    msg, _ = await self.fs._aprocess_large_message(
                        ToolMessage(content=content, tool_call_id=call_id or name, name=name), self.fs.backend)
                    content = msg.content
                except Exception:  # noqa: BLE001
                    pass
        blocks = _blocks(content)
        output = _text(blocks)
        failed = failed or output.lower().startswith("error")
        self.acted = True
        if name == "write_todos":
            todos = args.get("todos") or []
            plan = "\n".join(f"{_TODO_MARK.get(t.get('status', ''), '[ ]')} {t.get('content', '')}" for t in todos)
            await self.worklog.write(f"Plan\n{plan}")
        else:
            entry = f"{'Tool failed' if failed else 'Tool'} · {name}\n{_args(args)}"
            if output:
                entry += f"\n→ {_clip(output, 1200)}"
            await self.worklog.write(entry)
        await self.worklog.write(status="thinking…")
        if name in DELIVERY_TOOLS and not failed and output.strip():
            self.delivered.append(f"{name}: {output.strip()[:300]}")
        self.trajectory.append({"type": "tool", "tool": name, "state": {
            "status": "error" if failed else "completed", "input": args, "output": output[:2000]}})
        return blocks, failed

    # --- after the loop -----------------------------------------------------------

    async def incomplete(self, request: str, answer: str) -> bool:
        """The decision model's completion check (once a turn, with steps left)."""
        decision = self.ctx.decision
        if decision is None or not decision.enabled or self.guard.budget - self.guard.calls < 2:
            return False
        return await completion.incomplete(decision, request, answer, self.delivered)


async def _nothing() -> str:
    return ""


@dataclass
class EditorRun(Run):
    """A harness editor session (harness/editor.py), billed as the agent's learning."""

    translate = False

    key: str
    node_url: str
    secret: str
    space: str
    agent_vm: str
    system: str = ""
    root_session: str = ""
    calls: int = 0
    budget: int = 40
    client: Any = None

    def http(self) -> Any:
        return self.client

    def upstream(self) -> tuple[str, dict[str, str]]:
        return (self.node_url.rstrip("/") + "/deepagents/v1/learn/chat/completions",
                {"X-Tradera-Runtime": self.secret, "X-Tradera-Space": self.space, "X-Tradera-Agent": self.agent_vm})

    async def prepare(self, body: dict[str, Any], session: str, agent: str = "") -> dict[str, Any] | str:
        self.calls += 1
        messages = list(body.get("messages") or [])
        if messages and messages[0].get("role") == "system" and self.system and agent in ("", "editor"):
            # The editor's mission first (not on OpenCode compacting its session); OpenCode's own (its working directory
            # is the editor's evidence) after it.
            text = convert.text_of(messages[0].get("content"))
            messages[0] = {"role": "system", "content": (self.system + "\n\n" + text).strip()}
        if self.calls >= self.budget:
            body.pop("tools", None)
            body.pop("tool_choice", None)
            messages.append(convert.note_message(NOTE + "No steps are left: write your notes block now."))
        body["messages"] = messages
        body["model"] = "default"
        body.pop("max_tokens", None)
        return body


