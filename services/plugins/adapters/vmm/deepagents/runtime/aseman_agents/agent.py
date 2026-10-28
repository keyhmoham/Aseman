"""Running an aseman agent as a deep agent.

One deep agent per turn, assembled from the agent's definition and the turn's
scope, on the agent's durable LangGraph thread (one per agent per room):

* model — the node's metered, OpenAI-compatible LLM endpoint of the turn;
* backend — the space's shared sandbox (shell and files, shared by every agent);
* planning (``write_todos``), the filesystem, summarization, prompt caching and
  tool-call patching — the deep agents harness;
* skills — the agent's own skills and the space's shared ones, as SKILL.md
  files in the sandbox, loaded progressively;
* memory — OpenViking: the space's shared notes and the agent's own in the
  system prompt, what is relevant recalled with each message, memory tools,
  and every turn committed to an OpenViking session that memories are
  extracted from (see memory.py);
* Code Mode — Cloudflare search/execute is the capability-calling system
  (``codemode_search`` / ``codemode_execute``; see codemode.py): connected
  apps, platform tools, the project timeline, the shared computer and the
  space's agents are one OpenAPI surface under ``/apps``, ``/platform``,
  ``/timeline``, ``/sandbox`` and ``/agents``, and straightforward jobs are
  done in one execute. Fallback (Code Mode
  off or MCP down): direct LLM tools + app deferral (apps.py) and
  ``timeline_*`` (timeline.py), with a visible system note;
* subagents — the ``task`` tool, delegating to the space's agents over room
  messages (see subagents.py), plus background delegation tools;
* human in the loop — ``ask_user`` and any tool in the agent's interrupt_on
  pause the thread on a question people answer in the room;
* harness tools — messaging, sandbox FS/shell, planning and swarm stay
  native LLM tools (interrupts, shared computer, turn UX);
* the swarm — a lead sets up a team from the space, the marketplace and new
  specialists and runs plans with it in parallel (see swarm/); a delegated
  task that reaches a busy agent runs as a parallel instance of it;
* self-improvement — each agent's playbook in the space, evolved with GEPA
  from its own turns (see improve/);
* work log — every step written to the room as the agent works;
* decisions — when the node admin turned on a decision model, routing and
  low-risk approvals go to it (see decision/).
"""

from __future__ import annotations

import asyncio
import hashlib
import inspect
import json
import logging
import os
import re
import uuid
from dataclasses import dataclass
from typing import Any, Callable

from deepagents import create_deep_agent
from langchain_core.exceptions import ContextOverflowError
from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from langgraph.errors import GraphRecursionError
from langgraph.types import Command

from . import apps as applib, codemode as codemodelib, economy, guard as guardlib, memory as memlib, prompts, subagents, swarm as swarmlib, team as teamlib, timeline as timelinelib, tools as toollib
from .context import AgentDef, DecisionConfig, Turn, TurnContext
from .decision import DecisionClient, DecisionMiddleware
from .decision import approval as decision_approval
from .gateway import Gateway, GatewayError
from .sandbox import WORKSPACE, AsemanSandbox, FilesUnreadable
from .store import Question, Store
from .worklog import WorkLog, WorkLogMiddleware

log = logging.getLogger("aseman.agents")

SHARED_SKILLS = f"{WORKSPACE}/.aseman/skills/shared/"
# Where agents kept their notes before OpenViking: read once, to seed it.
LEGACY_SPACE_NOTES = f"{WORKSPACE}/AGENTS.md"
# Attached file text shown with a message, in all; the rest is read with read_attachment.
ATTACHMENTS_MAX_CHARS = 60_000
_OVERFLOW = ("context_length_exceeded", "context length", "context window", "context limit", "maximum context",
             "prompt is too long", "input is too long", "too many input tokens", "input token count",
             "maximum number of tokens allowed", "reduce the length of the messages")
APPROVE = re.compile(r"^\s*(y|yes|ok|okay|approve[d]?|go( ahead)?|allow(ed)?|sure|confirm(ed)?|👍)\b", re.I)

ModelFactory = Callable[[AgentDef, Gateway], BaseChatModel]


def openai_model(agent: AgentDef, gateway: Gateway) -> BaseChatModel:
    """The agent's model, behind the node's metered LLM proxy of the turn."""
    from langchain_openai import ChatOpenAI

    kwargs: dict[str, Any] = {}
    if agent.max_tokens:
        kwargs["max_tokens"] = agent.max_tokens
    if agent.reasoning_effort:
        kwargs["reasoning_effort"] = agent.reasoning_effort
    # Streamed, so the node can show the answer in the room as it is written
    # (it reads the stream; this runtime still gets each response whole).
    # ASEMAN_STREAM=0 turns that off for a provider that cannot stream.
    # The node owns provider deadlines and returns a precise first-event or
    # stream-idle failure. Retrying the whole agent step here used to hide that
    # failure and could turn one dead stream into several minutes of silence.
    model = ChatOpenAI(model=agent.model or "default", base_url=gateway.llm_base_url, api_key=gateway.token,
                       use_responses_api=False, timeout=330, max_retries=0,
                       streaming=os.environ.get("ASEMAN_STREAM", "1") != "0", **kwargs)
    if agent.context_window:
        try:
            model.profile = {**(model.profile or {}), "max_input_tokens": agent.context_window}
        except Exception:  # noqa: BLE001 - profile is advisory
            pass
    return model


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-") or "agent"


@dataclass
class Outcome:
    reply: str
    status: str = "done"  # done | awaiting | failed | cancelled
    answered: bool = False
    error: str = ""

    def json(self) -> dict[str, Any]:
        return {"reply": self.reply, "status": self.status, "answered": self.answered, "error": self.error}


class Runner:
    """Runs agent turns. One per runtime process."""

    def __init__(self, store: Store, checkpointer: Any, *, model_factory: ModelFactory = openai_model,
                 gateway_factory: Callable[[str, str], Gateway] = Gateway,
                 memory_settings: memlib.Settings | None = None, improver: Any = None) -> None:
        self.store = store
        # The agents' self-improvement (improve.Improver); None: agents keep their prompts.
        self.improver = improver
        self.memory_settings = memory_settings or memlib.Settings.from_env()
        self.recorder = memlib.Recorder()
        self.checkpointer = checkpointer
        self.model_factory = model_factory
        self.gateway_factory = gateway_factory
        self._locks: dict[str, asyncio.Lock] = {}
        self._prepared: dict[str, str] = {}

    def _lock(self, thread: str) -> asyncio.Lock:
        return self._locks.setdefault(thread, asyncio.Lock())

    # --- entry points -------------------------------------------------------

    async def prompt(self, req: dict[str, Any]) -> Outcome:
        ctx = self._context(req)
        self._instance(ctx)
        try:
            async with self._lock(ctx.thread_id):
                pending = self.store.question_for_thread(ctx.thread_id)
                if pending is not None:
                    # The room moved on while the agent waited: the open
                    # question is closed with the new message, which the
                    # agent reads as it resumes.
                    note = (f"No answer yet. Meanwhile {ctx.turn.sender_name or 'someone'} wrote: "
                            f"{ctx.turn.message}")
                    return await self._resume(ctx, pending, note, approve=False)
                return await self._run(ctx, await self._input(ctx))
        finally:
            await self._close(ctx)

    async def answer(self, req: dict[str, Any]) -> Outcome:
        ctx = self._context(req)
        try:
            # Restricted requests have separate threads; find the exact question
            # before selecting its thread and retain the originating policy.
            pending = next((q for q in self.store.questions(ctx.agent.vm_id, ctx.space)
                            if (q.id == ctx.turn.question_id if ctx.turn.question_id
                                else q.room_id == ctx.room)), None)
            if pending is None:
                return Outcome(reply="", answered=False)
            ctx.turn.no_sandbox = ctx.turn.no_sandbox or pending.no_sandbox
            ctx.turn.no_memory = ctx.turn.no_memory or pending.no_memory
            ctx.turn.request_scope = pending.request_scope
            ctx.turn.instance = pending.instance
            ctx.generation = self.store.generation(ctx.base_thread)
            async with self._lock(ctx.thread_id):
                pending = self.store.question_for_thread(ctx.thread_id)
                if pending is None or (ctx.turn.question_id and ctx.turn.question_id != pending.id):
                    return Outcome(reply="", answered=False)
                who = ctx.turn.sender_name or "A person"
                outcome = await self._resume(ctx, pending, f"{who}: {ctx.turn.message}",
                                             approve=bool(APPROVE.match(ctx.turn.message)))
                outcome.answered = True
                return outcome
        finally:
            await self._close(ctx)

    def questions(self, vm_id: str, space_id: str) -> list[dict[str, Any]]:
        return [q.public() for q in self.store.questions(vm_id, space_id)]

    async def forget_room(self, space_id: str, room_id: str) -> int:
        """Forgets every agent's conversation of a room: a room thread was
        deleted (an app's temporary thread once its agent is done). Returns
        how many agent threads were dropped."""
        if not space_id or not room_id:
            return 0
        threads = set(self.store.forget_room(space_id, room_id))
        conn = getattr(self.checkpointer, "conn", None)
        if conn is not None:
            from .store import _room_patterns
            try:
                for pattern in _room_patterns(space_id, room_id):
                    async with conn.execute("SELECT DISTINCT thread_id FROM checkpoints WHERE thread_id LIKE ?",
                                            (pattern,)) as cur:
                        threads.update(row[0] for row in await cur.fetchall())
            except Exception as exc:  # noqa: BLE001 - a saver without that table
                log.warning("listing the room's checkpoints failed: %s", exc)
        for thread in threads:
            async with self._lock(thread):
                try:
                    await self.checkpointer.adelete_thread(thread)
                except Exception as exc:  # noqa: BLE001 - the rest still go
                    log.warning("forgetting thread %s failed: %s", thread, exc)
            self._locks.pop(thread, None)
        return len(threads)

    # --- a turn -------------------------------------------------------------

    def _instance(self, ctx: TurnContext) -> None:
        """A delegated task that reaches an agent busy in the room runs as a
        parallel instance of it, on a thread of its own (team.TASK_TAG), rather
        than waiting for the agent's current work to finish."""
        tag = teamlib.task_tag(ctx.turn.message)
        if not tag or not self._lock(ctx.thread_id).locked():
            return
        ctx.turn.instance = tag
        ctx.generation = self.store.generation(ctx.base_thread)
        log.info("agent %s busy in room %s: task %s runs as a parallel instance", ctx.agent.name, ctx.room, tag)

    def _context(self, req: dict[str, Any]) -> TurnContext:
        gateway = self.gateway_factory(req["gateway"], req["token"])
        turn = Turn.from_payload(req.get("turn") or {})
        if (turn.no_memory or turn.no_sandbox) and not turn.request_scope:
            turn.request_scope = turn.message_id or uuid.uuid4().hex
        ctx = TurnContext(gateway=gateway, agent=AgentDef.from_payload(req.get("agent") or {}), turn=turn,
                          decision_config=DecisionConfig.from_payload(req.get("decision")))
        ctx.generation = self.store.generation(ctx.base_thread)
        ctx.memory = memlib.Memory.for_turn(ctx, self.memory_settings)
        ctx.timeline = bool(req.get("timeline")) and not turn.no_memory
        ctx.codemode = bool(req.get("codemode"))
        ctx.opencode = bool(req.get("opencode"))
        models = req.get("memory")
        if ctx.memory is not None and isinstance(models, dict):
            ctx.memory.recall_enabled = bool(models.get("recall"))
            ctx.memory.learn_enabled = bool(models.get("learn"))
        return ctx

    async def _close(self, ctx: TurnContext) -> None:
        if ctx.memory is not None:
            await ctx.memory.aclose()
        await ctx.gateway.aclose()

    async def _build(self, ctx: TurnContext) -> tuple[Any, guardlib.TurnGuard]:
        agent = ctx.agent
        decision = ctx.decision_config
        ctx.decision = DecisionClient(ctx.gateway, decision.model) if decision else None
        model = self.model_factory(agent, ctx.gateway)
        ctx.llm = model
        members = await teamlib.team(ctx)
        await ctx.space_tools()
        backend = None if ctx.turn.no_sandbox else AsemanSandbox(ctx)
        if backend is not None and not ctx.turn.no_memory:
            await self._prepare_sandbox(ctx, backend)

        tools = toollib.communication_tools(ctx)
        if agent.lead:
            tools.append(toollib.recruit_tool(ctx))
            # The swarm: a team from the space, the marketplace and new
            # specialists, and plans run in parallel (see swarm/).
            tools += swarmlib.swarm_tools(ctx, self.store)
        # Code Mode is the capability-calling system when its MCP is up.
        # If listing fails, fall back to direct tools and tell the model.
        codemode = await codemodelib.codemode_tools(ctx) if ctx.codemode else []
        via_codemode = bool(codemode)
        codemode_fallback = bool(ctx.codemode) and not via_codemode
        if codemode_fallback:
            log.warning("codemode enabled but MCP tools unavailable for space %s; falling back to direct tools", ctx.space)
        tools += await toollib.platform_tools(ctx, via_codemode=via_codemode)
        tools = toollib.filter_allowed(tools, agent.allowed_tools)
        if ctx.memory is not None:
            # Every agent has its memory, whatever tools it is allowed.
            tools += memlib.memory_tools(ctx.memory)
        timeline: list[Any] = []
        if ctx.timeline and not via_codemode:
            # Timeline is under /timeline/… in Code Mode OpenAPI when Code Mode is up.
            timeline = await timelinelib.timeline_tools(ctx)
            tools += timeline
        tools += codemode
        # App deferral only applies to the native app-tool fallback path.
        load, app_tools = applib.deferral(tools)
        tools += load
        for t in tools:
            # Docstring indentation is sent to the model on every call: drop it.
            if isinstance(getattr(t, "description", None), str):
                t.description = inspect.cleandoc(t.description)

        interrupt_on: dict[str, Any] = {"ask_user": {"allowed_decisions": ["respond"]}}
        for name in agent.interrupt_on:
            if name and name != "ask_user":
                # A call the decision model approved (written on the agent's
                # message) runs without waiting; every other call waits. Read
                # from the thread, so a turn resumes the same way even when the
                # admin changed the decision model meanwhile.
                interrupt_on[name] = {"allowed_decisions": ["approve", "reject"],
                                      "when": decision_approval.needs_person}

        own = f"{WORKSPACE}/.aseman/agents/{slug(agent.name)}"
        restricted = ctx.turn.no_sandbox or ctx.turn.no_memory
        system = prompts.system_prompt(agent, ctx.turn.context, via_codemode=via_codemode, opencode=ctx.opencode)
        if ctx.turn.no_sandbox:
            system += "\n\nFor this request, sandbox access is disabled. Answer and collaborate using the available platform tools. Do not wake, use or request access to a computer or sandbox."
        if ctx.turn.no_memory:
            system += "\n\nProcess this request freshly. Do not read or use prior room/space conversations, saved notes, AGENTS.md, or other memory. Only the current request, its attachments and work delegated during this request are context. Do not write memory for this request."
        if via_codemode:
            system += "\n\n" + codemodelib.CODEMODE_PROMPT
            if ctx.timeline and await timelinelib.available(ctx):
                system += "\n\n" + timelinelib.timeline_prompt(via_codemode=True)
        else:
            if codemode_fallback:
                system += "\n\n" + prompts.FALLBACK_NOTE
            if timeline:
                system += "\n\n" + timelinelib.timeline_prompt(via_codemode=False)
        worklog = WorkLog(ctx)
        if codemode_fallback:
            await worklog.write(
                "Code Mode unavailable — using direct app/platform/timeline tools for this turn",
                status="Code Mode unavailable; using direct tools",
            )
        if restricted:
            for skill in agent.skills:
                system += f"\n\nSkill: {skill.name}\n{skill.instructions}"
        if self.improver is not None:
            # The agent's playbook in this space, learned from its own turns.
            system = self.improver.prepare(ctx, system)
        skills = [] if restricted else [SHARED_SKILLS, f"{own}/skills/"]
        memory: list[Any] = []
        if ctx.memory is not None:
            # Loaded once per turn: the system prompt stays the same on every call.
            memory.append(memlib.OpenVikingMemory(await ctx.memory.notes(self._legacy_notes(ctx, backend))))
        turn_guard = guardlib.TurnGuard(guardlib.max_calls(agent.max_turns))
        middleware = [*app_tools, *economy.middleware(model, backend, skills=skills), *memory,
                      WorkLogMiddleware(worklog), turn_guard]
        if ctx.decision is not None:
            middleware.insert(0, DecisionMiddleware(
                ctx.decision, lead=agent.lead,
                agents=[m for m in members if m.kind == "agent" and m.runtime],
                interrupt_on=set(interrupt_on), auto_approve=bool(decision and decision.auto_approve),
                worklog=worklog))
        graph = create_deep_agent(
            model=model,
            tools=tools,
            system_prompt=system,
            middleware=middleware,
            subagents=await subagents.subagents(ctx, members),
            skills=skills,
            backend=backend,
            interrupt_on=interrupt_on,
            checkpointer=self.checkpointer,
            name=slug(agent.name),
        )
        return graph, turn_guard

    def _legacy_notes(self, ctx: TurnContext, backend: AsemanSandbox | None) -> Callable[[str], Any]:
        """The notes an agent kept in the sandbox before its memory moved to
        OpenViking, to start its OpenViking notes from. Read from the project's
        stored files only: this never starts the computer."""
        paths = {memlib.SPACE_NOTES: LEGACY_SPACE_NOTES,
                 ctx.memory.own_notes: f"{WORKSPACE}/.aseman/agents/{slug(ctx.agent.name)}/AGENTS.md"}

        async def seed(uri: str) -> str | None:
            path = paths.get(uri)
            if backend is None or path is None:
                return None
            try:
                stored = await asyncio.to_thread(backend.read_stored, path)
            except Exception:  # noqa: BLE001
                return None
            return stored.decode("utf-8", "replace") if stored else None

        return seed

    async def _prepare_sandbox(self, ctx: TurnContext, backend: AsemanSandbox) -> None:
        """Lay out the agent's skills in the shared sandbox (once per definition
        and space)."""
        agent = ctx.agent
        if not ctx.sandbox_bot:
            return
        own = f"{WORKSPACE}/.aseman/agents/{slug(agent.name)}"
        files: list[tuple[str, bytes]] = []
        for skill in agent.skills:
            name = slug(skill.name)
            front = {"name": name, "description": (skill.description or skill.name)[:1000]}
            if skill.tools:
                front["allowed-tools"] = " ".join(skill.tools)
            header = "\n".join(f"{k}: {json.dumps(v)}" for k, v in front.items())
            files.append((f"{own}/skills/{name}/SKILL.md",
                          f"---\n{header}\n---\n\n# {skill.name}\n\n{skill.instructions.strip()}\n".encode()))
        digest = hashlib.sha256(repr((agent.name, files)).encode()).hexdigest()
        key = f"{ctx.space}:{agent.vm_id}"
        if self._prepared.get(key) == digest:
            return
        # Laid out in the project's stored files when the provider allows it, so
        # a turn that only talks never starts the computer for this.
        try:
            stored = await asyncio.to_thread(backend.store_files, files)
        except FilesUnreadable:
            return  # not now: the next turn lays it out, and nothing is started for it
        if not stored:
            result = await backend.aexecute(f"mkdir -p {SHARED_SKILLS} {own}/skills")
            if result.exit_code not in (0, None):
                log.warning("sandbox layout failed: %s", result.output[:300])
                return
            if files:
                await backend.aupload_files(files)
        self._prepared[key] = digest

    async def _input(self, ctx: TurnContext) -> dict[str, Any]:
        turn = ctx.turn
        parts: list[str] = []
        if ctx.memory is not None:
            ctx.memory.fresh = await self._fresh(ctx)
            earlier = await self._earlier(ctx) if ctx.memory.fresh else ""
            if earlier:
                parts.append("Earlier in this room (your memory of it, summarized):\n" + earlier + "\n")
        catch_up = await self._catch_up(ctx)
        if catch_up:
            parts.append("Messages in the room since your last turn:\n" + catch_up + "\n")
        recalled = await self._recall(ctx)
        if recalled:
            # With the message rather than in the system prompt: it changes
            # every turn, and the prompt cache would stop matching.
            parts.append("From your memory (it may be relevant):\n" + recalled + "\n")
        who = turn.sender_name or "Someone"
        ident = f" ({turn.sender_id})" if turn.sender_id else ""
        # No message id here: the agent answers this message with its final
        # answer, never by replying to it with send_message.
        if turn.note:
            # What changes from turn to turn stays out of the system prompt, so
            # the provider's prompt cache still matches it.
            parts.append(turn.note + "\n")
        parts.append(f"{who}{ident} wrote:\n{turn.message}")
        blocks: list[dict[str, Any]] = []
        room = ATTACHMENTS_MAX_CHARS
        for att in turn.attachments:
            line = f"\nAttached file {att.get('name', '')} (file id {att.get('id', '')}, {att.get('mime', '')})"
            if att.get("content") and room > 0:
                shown = att["content"][:min(20000, room)]
                room -= len(shown)
                line += f":\n{shown}"
                if len(shown) < len(att["content"]):
                    line += "\n[… the rest is not shown: read it with read_attachment]"
            else:
                line += " — read it with read_attachment."
            parts.append(line)
            if att.get("image_data"):
                mime = att.get("image_mime") or "image/jpeg"
                blocks.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64,{att['image_data']}"}})
        text = "\n".join(parts)
        content: Any = [{"type": "text", "text": text}, *blocks] if blocks else text
        return {"messages": [HumanMessage(content=content)]}

    async def _fresh(self, ctx: TurnContext) -> bool:
        """Whether the thread's conversation starts with this turn."""
        try:
            return await self.checkpointer.aget_tuple({"configurable": {"thread_id": ctx.thread_id,
                                                                        "checkpoint_ns": ""}}) is None
        except Exception:  # noqa: BLE001 - assume it goes on
            return False

    async def _earlier(self, ctx: TurnContext) -> str:
        """What the room's session keeps of the conversations before this one."""
        try:
            return await ctx.memory.earlier()
        except Exception as exc:  # noqa: BLE001 - the turn goes on without it
            log.warning("openviking session context failed: %s", exc)
            return ""

    async def _recall(self, ctx: TurnContext) -> str:
        """What the agent's memory holds about the message (the notes are in
        the system prompt already)."""
        if ctx.memory is None or not ctx.memory.recall_enabled:
            return ""
        try:
            return await ctx.memory.recall(ctx.turn.message, exclude=[memlib.SPACE_NOTES, ctx.memory.own_notes])
        except Exception as exc:  # noqa: BLE001 - the turn goes on without it
            log.warning("openviking recall failed: %s", exc)
            return ""

    def _record(self, ctx: TurnContext, outcome: Outcome, steps: list[Any] | None = None) -> Outcome:
        """Adds a finished turn (``steps``: its messages) to the agent's
        OpenViking session, and the text files attached to it to the space's."""
        if ctx.memory is not None and ctx.memory.learn_enabled and outcome.reply:
            files = [a for a in ctx.turn.attachments if a.get("content")] if ctx.memory.recall_enabled else []
            self.recorder.record(ctx.memory, memlib.turn_messages(ctx, ctx.turn.message, outcome.reply, steps), files)
        return outcome

    async def _catch_up(self, ctx: TurnContext) -> str:
        """What was said in the room since the agent last read it."""
        if ctx.turn.no_memory:
            return ""
        seen = self.store.seen(ctx.thread_id)
        body: dict[str, Any] = {"space": ctx.space, "room": ctx.room, "limit": 40}
        if seen:
            body["after"] = seen
        try:
            out = await ctx.gateway.call("spaces", "message_list", body)
        except GatewayError:
            return ""
        messages = out.get("messages") or []
        if not seen:
            messages = list(reversed(messages))  # newest first without a cursor
        if messages:
            self.store.mark_seen(ctx.thread_id, str(messages[-1].get("created_at", "")))
        shown = [m for m in messages if m.get("id") != ctx.turn.message_id and m.get("kind") != "log"
                 and m.get("sender_id") != ctx.agent.account_id]
        # Enough to follow the room; read_room gives the agent more when it needs it.
        return toollib._format_messages(shown[-20:], clip=600)

    async def _run(self, ctx: TurnContext, payload: Any, *, fresh_retry: bool = True) -> Outcome:
        log.info("turn %s agent=%s space=%s room=%s", ctx.thread_id, ctx.agent.name, ctx.space, ctx.room)
        graph = config = None
        before = 0
        try:
            graph, turn_guard = await self._build(ctx)
            # The turn is bounded by its model calls (TurnGuard); the graph's
            # own recursion limit (the deep agents default) is only a backstop.
            config = {"configurable": {"thread_id": ctx.thread_id}}
            before = len((await graph.aget_state(config)).values.get("messages") or [])
            await graph.ainvoke(payload, config)
            state = await graph.aget_state(config)
        except asyncio.CancelledError:
            raise
        except GatewayError as exc:
            return Outcome(reply="", status="failed", error=str(exc))
        except GraphRecursionError as exc:
            # A backstop only (the call budget ends the turn first): still
            # report what was done rather than nothing.
            log.warning("turn %s hit the recursion limit", ctx.thread_id)
            return Outcome(reply=await self._progress(graph, config), status="failed",
                           error=f"{type(exc).__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001 - the turn fails, the runtime goes on
            if _is_overflow(exc) and graph is not None:
                return await self._overflowed(ctx, graph, config, before, payload, exc, fresh_retry)
            log.exception("turn failed")
            return Outcome(reply="", status="failed", error=f"{type(exc).__name__}: {exc}")
        steps = (state.values.get("messages") or [])[before:]
        if state.interrupts:
            outcome = self._record(ctx, self._awaiting(ctx, state.interrupts), steps)
        else:
            self.store.drop_question(ctx.thread_id)
            outcome = self._record(ctx, Outcome(reply=_final_text(state.values.get("messages") or [])), steps)
        if self.improver is not None:
            # What the turn did and how it went is what the agent's playbook learns from.
            await self.improver.observe(ctx, outcome, steps, turn_guard, graph)
        return outcome

    async def _overflowed(self, ctx: TurnContext, graph: Any, config: Any, before: int, payload: Any,
                          exc: Exception, fresh_retry: bool) -> Outcome:
        """The conversation no longer fits the model's window even after
        compaction. Every later turn on it would fail the same way, so the
        thread starts a new conversation (it catches up on the room); when this
        turn has not run a tool yet, it runs again there at once."""
        try:
            messages = (await graph.aget_state(config)).values.get("messages") or []
        except Exception:  # noqa: BLE001
            messages = []
        acted = any(isinstance(m, ToolMessage) for m in messages[before:])
        old = ctx.thread_id
        ctx.generation = self.store.next_generation(ctx.base_thread)
        self.store.drop_question(old)
        log.warning("turn %s overflowed the model's window (%s); thread continues as %s", old, exc, ctx.thread_id)
        if fresh_retry and not acted and not isinstance(payload, Command):
            return await self._run(ctx, await self._input(ctx), fresh_retry=False)
        reply = await self._progress(graph, config, before)
        note = ("My working memory for this room was full, so I have started a fresh one; I still see the room's "
                "recent messages. Please ask again if anything is left to do.")
        return Outcome(reply=f"{reply}\n\n{note}".strip(), status="failed", error=f"{type(exc).__name__}: {exc}")

    async def _progress(self, graph: Any, config: Any, before: int = 0) -> str:
        """What a turn that could not finish got done: its last words and plan."""
        try:
            values = (await graph.aget_state(config)).values
        except Exception:  # noqa: BLE001
            return ""
        parts = []
        text = _final_text((values.get("messages") or [])[before:])
        if text:
            parts.append(text)
        todos = values.get("todos") or []
        if todos:
            marks = {"completed": "[x]", "in_progress": "[~]", "pending": "[ ]"}
            parts.append("Progress:\n" + "\n".join(f"- {marks.get(t.get('status', ''), '[ ]')} {t.get('content', '')}"
                                                   for t in todos if isinstance(t, dict)))
        return "\n\n".join(parts)

    async def _resume(self, ctx: TurnContext, pending: Question, answer: str, *, approve: bool) -> Outcome:
        decisions = []
        for action in pending.actions or [{"name": "ask_user"}]:
            if action.get("name") == "ask_user":
                decisions.append({"type": "respond", "message": answer})
            elif approve:
                decisions.append({"type": "approve"})
            else:
                decisions.append({"type": "reject", "message": f"Not approved. {answer}"})
        self.store.drop_question(ctx.thread_id)
        return await self._run(ctx, Command(resume={"decisions": decisions}))

    def _awaiting(self, ctx: TurnContext, interrupts: Any) -> Outcome:
        actions: list[dict[str, Any]] = []
        asks: list[str] = []
        options: list[str] = []
        approvals: list[str] = []
        for intr in interrupts:
            value = getattr(intr, "value", intr) or {}
            for req in value.get("action_requests") or []:
                name, args = req.get("name", ""), req.get("args") or {}
                actions.append({"name": name, "args": args})
                if name == "ask_user":
                    asks.append(str(args.get("question", "")).strip())
                    options += [str(o) for o in args.get("options") or []][:3]
                else:
                    approvals.append(f"`{name}` " + json.dumps(args, ensure_ascii=False, default=str)[:600])
        kind = "question" if asks and not approvals else "approval"
        text = "\n\n".join(asks)
        if approvals:
            text += ("\n\n" if text else "") + "May I run:\n" + "\n".join(f"- {a}" for a in approvals)
            options = options or ["Approve", "Reject"]
        q = Question(id=self.store.new_id(), vm_id=ctx.agent.vm_id, bot_id=ctx.agent.bot_id, agent=ctx.agent.name,
                     space_id=ctx.space, room_id=ctx.room, thread_id=ctx.thread_id, question=text.strip(),
                     kind=kind, options=options, actions=actions)
        q.no_sandbox, q.no_memory, q.request_scope = ctx.turn.no_sandbox, ctx.turn.no_memory, ctx.turn.request_scope
        q.instance = ctx.turn.instance
        self.store.put_question(q)
        reply = f"❓ {q.question}"
        if options:
            reply += "\n\n" + "\n".join(f"- {o}" for o in options)
        return Outcome(reply=reply, status="awaiting")


def _is_overflow(exc: BaseException) -> bool:
    """The model refused the request as larger than its window."""
    for _ in range(8):  # the error and what caused it
        if exc is None:
            return False
        if isinstance(exc, ContextOverflowError):
            return True
        text = str(exc).lower()
        if any(marker in text for marker in _OVERFLOW) and "rate limit" not in text and "per min" not in text:
            return True
        exc = exc.__cause__ or exc.__context__
    return False


def _final_text(messages: list[Any]) -> str:
    for m in reversed(messages):
        if isinstance(m, AIMessage):
            text = m.text if isinstance(m.text, str) else str(m.content)
            if text.strip():
                return text.strip()
        elif isinstance(m, HumanMessage):
            break
    return ""
