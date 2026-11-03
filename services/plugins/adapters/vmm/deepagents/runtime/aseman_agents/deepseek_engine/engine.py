"""One agent turn, driven by headless DeepSeek Harness (``dsh``).

The harness brings its own agentic modules: the loop, its own memory (the
aseman-memory plugin over a per-space, per-agent store, loaded by dsh's own
instruction loader), its own swarm (subagents, Agent Teams, workflows),
planning and goals, and one dsh Session per agent per thread. Aseman wires
them in: the model is the agent's own on the platform LLM gateway (metered on
the turn), the space is reached through the Aseman MCP bridge, questions wait
in the platform's question store, hand-offs to other Aseman agents are room
tasks, and what the harness does shows in the agent's work log.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING, Any

from .. import team as teamlib
from ..context import TurnContext
from ..store import Question, Store
from . import profile as profilelib
from .cli import RunResult, RunSpec, TOKEN_ENV, default_binary, pause_path, thread_key
from .events import Parsed, ToolStep, parse_stream
from .memory import MemoryStore
from .mapping import APP_BUILDER, brief

if TYPE_CHECKING:
    from ..agent import Outcome

log = logging.getLogger("aseman.agents.deepseek_engine")

#: Failures that mean the saved dsh Session cannot be resumed (start afresh).
_STALE_SESSION = ("unknown session", "no stored session", "session not found", "unknown id",
                  "cannot adopt", "does not exist")


def default_home() -> Path:
    override = os.environ.get("ASEMAN_DSH_ENGINE_HOME", "").strip()
    if override:
        return Path(override)
    return Path(os.environ.get("ASEMAN_DATA_DIR", "/data")) / "dsh-engine"


class CliRunner:
    """Runs one headless dsh process. Tests substitute this."""

    def __init__(self, binary_path: str | None = None) -> None:
        self.binary = binary_path or default_binary()

    async def run(self, spec: RunSpec) -> RunResult:
        missing = "DeepSeek Harness (dsh) is not on the agent runtime (set ASEMAN_DSH_BIN)."
        try:
            proc = await asyncio.create_subprocess_exec(
                *spec.argv(), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                stdin=asyncio.subprocess.DEVNULL, env=spec.env(), cwd=spec.directory,
            )
        except FileNotFoundError as exc:
            raise FileNotFoundError(missing) from exc
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout())
        except asyncio.CancelledError:
            proc.kill()
            raise
        except asyncio.TimeoutError:
            proc.kill()
            return RunResult(stdout="", stderr="dsh run timed out", code=124)
        return RunResult(stdout=(stdout or b"").decode(errors="replace"),
                         stderr=(stderr or b"").decode(errors="replace"), code=proc.returncode or 0)


class DeepSeekEngine:
    def __init__(self, store: Store, *, home: Path | None = None, runner: CliRunner | None = None,
                 rows: set[str] | None = None) -> None:
        self.store = store
        self.home = Path(home) if home is not None else default_home()
        self.runner = runner or CliRunner()
        # The harness's own memory, on the engine's disk.
        self.memory = MemoryStore(self.home / "memory")
        # The installed profile's row ids (profile.available_rows), read once.
        self._rows = rows
        self._rows_read = rows is not None
        # Whether headless takes --approval-policy (dsh 0.2.2+).
        self.never_ask: bool | None = True if rows is not None else None

    async def rows(self) -> set[str] | None:
        if not self._rows_read:
            probe = self.home / "probe"
            self._rows = await asyncio.to_thread(profilelib.available_rows, self.runner.binary, probe)
            flags = await asyncio.to_thread(profilelib.headless_flags, self.runner.binary, probe)
            self.never_ask = "--approval-policy" in flags if flags else True
            self._rows_read = True
        return self._rows

    def _teams(self, rows: set[str] | None) -> bool:
        """Whether this dsh ships Agent Teams (the 0.2.2 line does)."""
        return rows is None or ("agent-team" in rows and "tool-agent-team" in rows)

    # --- entry points -------------------------------------------------------

    async def prompt(self, ctx: TurnContext, pending: Question | None = None) -> "Outcome":
        from ..agent import Outcome
        if pending is not None:
            # The room moved on while the agent waited: the question closes
            # with the new message, which the resumed session reads.
            note = f"No answer yet. Meanwhile {ctx.turn.sender_name or 'someone'} wrote: {ctx.turn.message}"
            self.store.drop_question(ctx.thread_id)
            self._clear_pause(ctx.thread_id)
            return await self._turn(ctx, note, Outcome)
        return await self._turn(ctx, "", Outcome)

    async def answer(self, ctx: TurnContext, pending: Question) -> "Outcome":
        from ..agent import Outcome
        who = ctx.turn.sender_name or "A person"
        self.store.drop_question(ctx.thread_id)
        self._clear_pause(ctx.thread_id)
        return await self._turn(ctx, f"Answer to your question \"{pending.question}\" — {who}: {ctx.turn.message}",
                                Outcome)

    async def chat(self, *, system: str, messages: list[dict], thread_id: str = "aseman-chat",
                   with_tools: bool = False, gateway: str = "", token: str = "",
                   account_id: str = "") -> tuple[str, str]:
        """Personal Aseman chat (self-chat / Talk) on DeepSeek Harness.

        ``gateway`` + ``token`` are a person-scoped session: its ``/llm`` is the
        assistant's platform model (billed to the person) and, ``with_tools``,
        its actions are the person's (the same bridge room turns use).
        """
        thread = (thread_id or "aseman-chat").strip() or "aseman-chat"
        mode = profilelib.llm_mode()
        if mode == profilelib.LLM_GATEWAY and not (gateway and token):
            return "", "personal chat on DeepSeek Harness needs the person's gateway session"
        key = thread_key("chat:" + thread)
        place = self.memory.personal(account_id) if account_id else None
        dirs = self._dirs(key, workdir=place.workdir if place else None)
        session = self._session(thread)
        mcp_env = self._base_env(dirs, thread=thread, gateway=gateway, token=token)
        mcp_env.update({"ASEMAN_ENGINE_MODE": "personal", "ASEMAN_ENGINE_ACCOUNT": account_id or ""})
        persona = _chat_persona(system, with_tools=with_tools)
        overlay = profilelib.Overlay(persona=persona, mcp_env=mcp_env, gateway=gateway, mode=mode,
                                     with_mcp=bool(with_tools and gateway and token))
        if place is not None:
            overlay.memory_root, overlay.memory_agent, overlay.agent_name = str(place.root), place.agent, "Aseman"
        profilelib.write(dirs["patch"], overlay, await self.rows())
        message = _chat_message(messages, resumed=bool(session))
        result, parsed = await self._run(dirs, message, session, token=token, mode=mode)
        if result is None:
            return "", parsed.error
        if parsed.session:
            self._save_session(thread, parsed.session)
        if parsed.error and not parsed.reply:
            return "", parsed.error[:2000]
        if parsed.reply:
            return parsed.reply, ""
        detail = (result.stderr or result.stdout or "dsh chat failed").strip()
        return "", detail[:2000]

    # --- a turn -------------------------------------------------------------

    async def _turn(self, ctx: TurnContext, continuation: str, outcome_cls):
        members = await self._members(ctx)
        rows = await self.rows()
        teams = self._teams(rows)
        mode = profilelib.llm_mode()
        # The run works in the agent's memory directory, so dsh's own
        # instruction loader reads its notes (none for a "no memory" request).
        place = None if ctx.turn.no_memory else self.memory.agent(ctx.space, ctx.agent.bot_id or ctx.agent.name)
        dirs = self._dirs(thread_key(ctx.thread_id), workdir=place.workdir if place else None)
        session = self._session(ctx.thread_id)
        mcp_env = self._base_env(dirs, thread=ctx.thread_id, gateway=ctx.gateway.base_url, token=ctx.gateway.token)
        mcp_env.update(self._room_env(ctx))
        overlay = profilelib.Overlay(
            persona=_persona(ctx, members, teams=teams, memory=place is not None),
            mcp_env=mcp_env, gateway=ctx.gateway.base_url,
            model="" if mode == profilelib.LLM_DEEPSEEK else _gateway_model(ctx),
            context_window=ctx.agent.context_window, max_tokens=ctx.agent.max_tokens,
            reasoning_effort=ctx.agent.reasoning_effort if mode == profilelib.LLM_DEEPSEEK else "",
            lead=ctx.agent.lead, team=teams and ctx.agent.lead and any(m.kind == "agent" for m in members),
            mode=mode,
            memory_root=str(place.root) if place else "", memory_agent=place.agent if place else "",
            agent_name=ctx.agent.name,
        )
        profilelib.write(dirs["patch"], overlay, rows)
        message = _message(ctx, continuation)
        await self._log(ctx, status=f"DeepSeek Harness · {_route_label(mode, overlay)}")
        result, parsed = await self._run(dirs, message, session, token=ctx.gateway.token, mode=mode)
        if result is None:
            return outcome_cls(reply="", status="failed", error=parsed.error)
        if parsed.session:
            self._save_session(ctx.thread_id, parsed.session)
        if parsed.todos:
            await self._log(ctx, status=_todo_status(parsed.todos))
        swarm = _swarm_note(parsed.tools)
        if swarm:
            await self._log(ctx, text=swarm)
        pause = self._pause(ctx.thread_id)
        if pause is not None:
            return self._awaiting(ctx, pause, outcome_cls)
        if parsed.error and not parsed.reply:
            return outcome_cls(reply="", status="failed", error=parsed.error[:2000])
        if parsed.reason == "cancelled":
            return outcome_cls(reply="", status="cancelled", error="the dsh run was cancelled")
        if result.code == 0 or parsed.reply:
            reply = parsed.reply or "Done."
            await self._log(ctx, text=reply[:500], status="")
            return outcome_cls(reply=reply, status="done")
        detail = (result.stderr or result.stdout or "dsh run failed").strip()
        return outcome_cls(reply="", status="failed", error=detail[:2000])

    async def _run(self, dirs: dict[str, Path], message: str, session: str, *, token: str,
                   mode: str) -> tuple[RunResult | None, Parsed]:
        """One dsh run; a session dsh no longer has is started afresh once."""
        extra = {"ASEMAN_ENGINE_PATCH": str(dirs["patch"])}
        if mode == profilelib.LLM_DEEPSEEK:
            extra["DEEPSEEK_API_KEY"] = profilelib.deepseek_key()
        else:
            extra[TOKEN_ENV] = token
        for attempt in range(2):
            spec = RunSpec(binary=self.runner.binary, patch=dirs["patch"], directory=str(dirs["scratch"]),
                           message=message, home=dirs["home"], session=session, extra_env=extra,
                           never_ask=self.never_ask is not False)
            try:
                result = await self.runner.run(spec)
            except FileNotFoundError as exc:
                return None, Parsed(error=str(exc))
            parsed = parse_stream(result.stdout)
            stale = session and not parsed.reply and _stale(parsed.error or result.stderr)
            if attempt == 0 and stale:
                log.info("dsh session %s is gone; starting the thread afresh", session)
                session = ""
                continue
            if not parsed.error and result.code != 0 and not parsed.reply:
                parsed.error = (result.stderr or result.stdout or f"dsh exited {result.code}").strip()[-2000:]
            return result, parsed
        return None, Parsed(error="dsh run failed")

    # --- environment ----------------------------------------------------------

    def _dirs(self, key: str, *, workdir: Path | None = None) -> dict[str, Path]:
        dirs = {
            "home": self.home / "home" / key,
            "scratch": workdir or (self.home / "scratch" / key),
            "patch": self.home / "patches" / key / "aseman.patch.yml",
        }
        dirs["home"].mkdir(parents=True, exist_ok=True)
        dirs["scratch"].mkdir(parents=True, exist_ok=True)
        return dirs

    def _base_env(self, dirs: dict[str, Path], *, thread: str, gateway: str, token: str) -> dict[str, str]:
        env = {
            "ASEMAN_ENGINE_GATEWAY": gateway,
            "ASEMAN_ENGINE_TOKEN": token,
            "ASEMAN_ENGINE_HOME": str(self.home),
            "ASEMAN_ENGINE_PROCESS_HOME": str(dirs["home"]),
            "ASEMAN_ENGINE_DIR": str(dirs["scratch"]),
            "ASEMAN_ENGINE_PATCH": str(dirs["patch"]),
            "ASEMAN_ENGINE_THREAD": thread,
            "ASEMAN_ENGINE_KIND": "deepseek",
            "ASEMAN_DSH_BIN": self.runner.binary,
            "ASEMAN_DSH_NEVER_ASK": "0" if self.never_ask is False else "1",
            "PYTHONPATH": _pythonpath(),
        }
        for key in ("ASEMAN_SWARM_PARALLEL", "ASEMAN_DSH_ENGINE_TIMEOUT", "ASEMAN_DSH_ENGINE_LLM",
                    "ASEMAN_DSH_ENGINE_MODEL", "ASEMAN_DSH_ENGINE_WEB", "ASEMAN_DSH_ENGINE_TOOL_TIMEOUT",
                    "ASEMAN_DATA_DIR"):
            if os.environ.get(key):
                env[key] = os.environ[key]
        return env

    def _room_env(self, ctx: TurnContext) -> dict[str, str]:
        env = {
            "ASEMAN_ENGINE_MODE": "room",
            "ASEMAN_ENGINE_SPACE": ctx.space,
            "ASEMAN_ENGINE_ROOM": ctx.room,
            "ASEMAN_ENGINE_ACCOUNT": ctx.agent.account_id,
            "ASEMAN_ENGINE_AGENT": ctx.agent.name,
            "ASEMAN_ENGINE_BOT": ctx.agent.bot_id,
            "ASEMAN_ENGINE_LEAD": "1" if ctx.agent.lead else "",
            "ASEMAN_ENGINE_TIMELINE": "1" if ctx.timeline else "",
            "ASEMAN_ENGINE_CODEMODE": "1" if ctx.codemode else "",
            "ASEMAN_ENGINE_PROGRAMMER": "1" if ctx.opencode else "",
        }
        return env

    # --- sessions, questions, log ---------------------------------------------

    def _session(self, thread_id: str) -> str:
        return str(self._sessions().get(thread_id) or "")

    def _save_session(self, thread_id: str, session: str) -> None:
        data = self._sessions()
        data[thread_id] = session
        path = self.home / "sessions.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def forget(self, thread_ids: list[str]) -> int:
        """Drop the dsh Sessions of these threads (a room thread was deleted)."""
        data = self._sessions()
        dropped = [t for t in thread_ids if data.pop(t, None) is not None]
        if dropped:
            (self.home / "sessions.json").write_text(json.dumps(data), encoding="utf-8")
        return len(dropped)

    def forget_room(self, space_id: str, room_id: str) -> int:
        data = self._sessions()
        threads = [t for t in data if space_id in t and room_id in t]
        return self.forget(threads)

    def _sessions(self) -> dict:
        path = self.home / "sessions.json"
        if not path.is_file():
            return {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _pause(self, thread_id: str) -> dict | None:
        path = pause_path(self.home, thread_id)
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if data.get("thread") not in ("", thread_id):
            return None
        return data

    def _clear_pause(self, thread_id: str) -> None:
        try:
            pause_path(self.home, thread_id).unlink(missing_ok=True)
        except OSError:
            pass

    def _awaiting(self, ctx: TurnContext, pause: dict, outcome_cls):
        question = str(pause.get("question") or "").strip() or "A question is waiting."
        options = [str(item) for item in pause.get("options") or []]
        q = Question(
            id=self.store.new_id(), vm_id=ctx.agent.vm_id, bot_id=ctx.agent.bot_id, agent=ctx.agent.name,
            space_id=ctx.space, room_id=ctx.room, thread_id=ctx.thread_id, question=question,
            kind="question", options=options, actions=[{"name": "ask_user", "args": {"question": question}}],
        )
        q.no_sandbox = ctx.turn.no_sandbox
        q.no_memory = ctx.turn.no_memory
        q.request_scope = ctx.turn.request_scope
        q.instance = ctx.turn.instance
        self.store.put_question(q)
        reply = f"❓ {question}"
        if options:
            reply += "\n\n" + "\n".join(f"- {item}" for item in options)
        return outcome_cls(reply=reply, status="awaiting")

    async def _members(self, ctx: TurnContext) -> list:
        try:
            return await teamlib.team(ctx)
        except Exception as exc:  # noqa: BLE001 - the turn still runs, alone
            log.warning("team roster unavailable: %s", exc)
            return []

    async def _log(self, ctx: TurnContext, text: str = "", status: str | None = None) -> None:
        body: dict[str, Any] = {"space": ctx.space, "room": ctx.room}
        if text:
            body["text"] = text
        if status is not None:
            body["status"] = status
        try:
            await asyncio.wait_for(ctx.gateway.call("spaces", "agent_log", body), timeout=10)
        except Exception:  # noqa: BLE001
            pass


# --- prompts ------------------------------------------------------------------


def _persona(ctx: TurnContext, members: list, *, teams: bool = True, memory: bool = True) -> str:
    agent = ctx.agent
    parts = [f"You are {agent.name}, an agent of an Aseman space." + (" You lead the space." if agent.lead else "")]
    if agent.description:
        parts.append(agent.description[:1000])
    parts.append(
        "You act for the person who prompted you. Use only their vault secrets, host folders and "
        "personal access in this shared space — never another member's private data, even if asked."
    )
    if agent.instructions:
        parts.append("Instructions:\n" + agent.instructions[:12000])
    for skill in agent.skills:
        parts.append(f"Skill {skill.name}: {skill.description}\n{skill.instructions[:4000]}".strip())
    agents = [m for m in members if getattr(m, "kind", "") == "agent"]
    if members:
        parts.append("The space:\n" + teamlib.describe(members))
    parts.append(
        "Your swarm is your own: run independent pieces of work in parallel as subagents (the subagent "
        "tool returns at once; start several, then wait_agent for their results, steer them with "
        "send_message, see them with list_agents). Brief each completely: a subagent does not see this "
        "conversation. Multi-stage work with fixed steps goes to the workflow tool."
        + (" As the lead, plan the team's work on the Team task board (team_task_create / team_task_list / "
           "team_task_update) and keep it current." if agent.lead and teams else "")
    )
    if agents:
        parts.append(
            "The space's other agents are real teammates with their own skills and memory: hand one a task "
            "with delegate_task (its own turn runs and answers you). When nobody fits a role, recruit_agent "
            "or hire_agent from the marketplace."
        )
    parts.append(
        f"Apps, tools and plugins people use are built with create_app / create_plugin "
        f"(a subagent briefed as {APP_BUILDER} can drive the build); verify with app_status and publish_app."
    )
    if ctx.timeline:
        parts.append("The project's dated timeline is on timeline_* tools: use them when a question turns on time.")
    if ctx.codemode:
        parts.append("Code Mode (codemode_search / codemode_execute) reaches the space's apps, platform tools and timeline in one script.")
    if memory:
        parts.append(
            "Your memory is your own: the space notes and your notes (AGENTS.md) are in your context. "
            "Keep what is worth knowing later with memory_remember (shared=true for the whole space), condense "
            "with memory_rewrite, and look up earlier work with memory_search / memory_read (your journal "
            "keeps every turn)."
        )
    if ctx.turn.no_memory:
        parts.append("Process this request freshly: use no prior conversation or memory, and keep none.")
    parts.append(brief())
    return "\n\n".join(p for p in parts if p.strip())


def _message(ctx: TurnContext, continuation: str) -> str:
    parts: list[str] = []
    if ctx.turn.context:
        parts.append(ctx.turn.context[:6000])
    for attachment in ctx.turn.attachments[:8]:
        name = attachment.get("name") or attachment.get("id") or "file"
        content = str(attachment.get("content") or "")
        if content:
            parts.append(f"Attached {name}:\n{content[:8000]}")
        else:
            parts.append(f"Attached {name} (id {attachment.get('id', '')}); read it with call_space_tool file_read.")
    if continuation:
        parts.append(continuation)
    else:
        who = ctx.turn.sender_name or "someone"
        parts.append(f"{who} wrote:\n{ctx.turn.message}")
    if ctx.turn.note:
        parts.append(ctx.turn.note[:1000])
    return "\n\n".join(parts)


def _chat_persona(system: str, *, with_tools: bool) -> str:
    parts = ["You are the person's Aseman in their Aseman chat."]
    if with_tools:
        parts.append(
            "Act as them on their account through the aseman MCP tools: spaces, rooms, threads, chats, "
            "participants, agents, apps, messages, files, posts, explore, marketplace, follows, wallet — "
            "anything they can do. Prefer named tools; use account_action / platform_call for anything "
            "else. Authorization is still theirs. Never claim something a tool did not confirm."
        )
    else:
        parts.append("Answer in one message, concisely.")
    if (system or "").strip():
        parts.append(system.strip()[:12000])
    return "\n\n".join(parts)


def _chat_message(messages: list[dict], *, resumed: bool) -> str:
    """The latest person message; the whole conversation when dsh has none of it."""
    turns = [m for m in messages or [] if str(m.get("content") or "").strip()]
    if not turns:
        return "Hello."
    if resumed and str(turns[-1].get("role") or "user") != "assistant":
        return str(turns[-1]["content"]).strip()[:12000]
    parts = []
    for msg in turns[-20:]:
        role = str(msg.get("role") or "user").lower()
        who = "Assistant" if role == "assistant" else ("System" if role == "system" else "Person")
        parts.append(f"{who}:\n{str(msg['content']).strip()[:6000]}")
    parts.append("Reply as the assistant to the latest person message.")
    return "\n\n".join(parts)


def _swarm_note(steps: list[ToolStep]) -> str:
    """The harness's swarm in this run, for the agent's work log."""
    spawned = [s for s in steps if s.tool in ("subagent", "subagent_fork")]
    tasks = [s for s in steps if s.tool == "team_task_create"]
    flows = [s for s in steps if s.tool in ("workflow", "ralph")]
    if not (spawned or tasks or flows):
        return ""
    parts = []
    if spawned:
        names = [str((s.input or {}).get("description") or "task") for s in spawned if isinstance(s.input, dict)]
        parts.append(f"swarm: {len(spawned)} subagent(s)" + (f" — {', '.join(names[:6])}" if names else ""))
    if tasks:
        parts.append(f"team board: {len(tasks)} task(s) created")
    if flows:
        parts.append(f"workflow: {len(flows)} run(s)")
    return "; ".join(parts)


def _todo_status(todos: list[dict[str, Any]]) -> str:
    active = [str(t.get("content") or t.get("activeForm") or "") for t in todos
              if str(t.get("status") or "") == "in_progress"]
    done = sum(1 for t in todos if str(t.get("status") or "") == "completed")
    head = active[0][:80] if active and active[0] else "planning"
    return f"{head} ({done}/{len(todos)})"


def _gateway_model(ctx: TurnContext) -> str:
    # The gateway serves the agent's own model whatever the id; name it for
    # the harness's selectors, else the stable alias.
    return (ctx.agent.model or "").strip() or profilelib.GATEWAY_MODEL


def _route_label(mode: str, overlay: profilelib.Overlay) -> str:
    if mode == profilelib.LLM_DEEPSEEK:
        return overlay.model or profilelib.deepseek_model(lead=overlay.lead)
    return overlay.model or profilelib.GATEWAY_MODEL


def _stale(detail: str) -> bool:
    text = (detail or "").lower()
    return "session" in text and any(marker in text for marker in _STALE_SESSION)


def _pythonpath() -> str:
    root = str(Path(__file__).resolve().parents[2])
    current = os.environ.get("PYTHONPATH", "")
    if root in current.split(":"):
        return current
    return root if not current else root + ":" + current


def timeout() -> float:
    try:
        return float(os.environ.get("ASEMAN_DSH_ENGINE_TIMEOUT") or "1800")
    except ValueError:
        return 1800.0


__all__ = ["DeepSeekEngine", "CliRunner", "default_home"]
