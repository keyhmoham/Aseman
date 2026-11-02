"""One agent turn, driven by headless ``opencode run``.

The platform gateway is used for actions (the team roster, the work log).
The model's tokens go to OpenCode, on a free model, never to ``/llm``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path

from ..context import TurnContext
from ..store import Question, Store
from .. import team as teamlib
from . import auth as authlib
from . import config as configlib
from .cli import RunResult, RunSpec, pause_path
from .events import Parsed, parse_stream
from .mapping import APP_AGENT, brief
from .models import (
    binary, fetch_free_models, is_free, is_opencode_model,
    KNOWN_FREE, KNOWN_FREE_GO, role_for, select,
)

log = logging.getLogger("aseman.agents.opencode_engine")


def default_home() -> Path:
    override = os.environ.get("ASEMAN_OPENCODE_ENGINE_HOME", "").strip()
    if override:
        return Path(override)
    return Path(os.environ.get("ASEMAN_DATA_DIR", "/data")) / "opencode-engine"


class CliRunner:
    """Runs one headless OpenCode process. Tests substitute this."""

    def __init__(self, binary_path: str | None = None) -> None:
        self.binary = binary_path or binary()

    async def run(self, spec: RunSpec) -> RunResult:
        missing = (
            "OpenCode CLI is not on the agent runtime (set ASEMAN_OPENCODE_BIN). "
            "This is the agentic engine, not the programmer OpenCode in the sandbox."
        )
        try:
            proc = await asyncio.create_subprocess_exec(
                *spec.argv(), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                env=spec.env(), cwd=spec.directory,
            )
        except FileNotFoundError as exc:
            raise FileNotFoundError(missing) from exc
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_timeout())
        except asyncio.CancelledError:
            proc.kill()
            raise
        except asyncio.TimeoutError:
            proc.kill()
            return RunResult(stdout="", stderr="opencode run timed out", code=124)
        return RunResult(
            stdout=(stdout or b"").decode(errors="replace"),
            stderr=(stderr or b"").decode(errors="replace"),
            code=proc.returncode or 0,
        )


class OpenCodeEngine:
    def __init__(self, store: Store, *, home: Path | None = None, runner: CliRunner | None = None,
                 model_lister=None) -> None:
        self.store = store
        self.home = Path(home) if home is not None else default_home()
        self.runner = runner or CliRunner()
        self.model_lister = model_lister

    async def prompt(self, ctx: TurnContext, pending: Question | None = None) -> "Outcome":
        from ..agent import Outcome
        if pending is not None:
            note = (f"No answer yet. Meanwhile {ctx.turn.sender_name or 'someone'} wrote: {ctx.turn.message}")
            self.store.drop_question(ctx.thread_id)
            self._clear_pause(ctx)
            return await self._turn(ctx, note, Outcome)
        return await self._turn(ctx, "", Outcome)

    async def answer(self, ctx: TurnContext, pending: Question) -> "Outcome":
        from ..agent import Outcome
        who = ctx.turn.sender_name or "A person"
        self.store.drop_question(ctx.thread_id)
        self._clear_pause(ctx)
        return await self._turn(ctx, f"{who}: {ctx.turn.message}", Outcome)

    async def chat(self, *, system: str, messages: list[dict], thread_id: str = "aseman-chat",
                   with_tools: bool = False, gateway: str = "", token: str = "",
                   account_id: str = "") -> tuple[str, str]:
        """Personal Aseman chat (Aseman self-chat / Talk) on a free OpenCode model.

        When ``with_tools`` and a person-scoped gateway token are provided, MCP
        space tools are enabled — the same bridge room turns use.
        """
        thread = (thread_id or "aseman-chat").strip() or "aseman-chat"
        listed = await self._models()
        turn_id = configlib.slug(thread)[:32]
        process_home = self.home / "home" / turn_id
        process_home.mkdir(parents=True, exist_ok=True)
        prefer_go = False
        if authlib.seed(process_home, self.home, binary=self.runner.binary) is not None:
            prefer_go = authlib.has_go_auth(self.home)
        candidates = _candidates("chat", listed, prefer_go=prefer_go)
        config_path = self.home / "configs" / turn_id / "opencode.json"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        scratch = self.home / "scratch" / turn_id
        scratch.mkdir(parents=True, exist_ok=True)
        session = self._session(thread)
        use_mcp = bool(with_tools and gateway and token)
        prompt = _chat_message(system, messages, with_tools=use_mcp)
        primary = configlib.agent_id("Aseman")
        last_detail = "opencode chat failed"
        for idx, model in enumerate(candidates):
            if idx > 0:
                await asyncio.sleep(_retry_delay())
            agents = [configlib.teammate(
                "Aseman", "Personal Aseman assistant", system or "", model, primary=True,
            )]
            mcp_env = {
                "ASEMAN_ENGINE_HOME": str(self.home),
                "ASEMAN_ENGINE_PROCESS_HOME": str(process_home),
                "ASEMAN_ENGINE_CONFIG": str(config_path),
                "ASEMAN_ENGINE_DIR": str(scratch),
                "ASEMAN_ENGINE_MODEL": model,
                "ASEMAN_ENGINE_THREAD": thread,
                "ASEMAN_ENGINE_MODE": "personal",
                "ASEMAN_ENGINE_ACCOUNT": account_id or "",
                "PYTHONPATH": _pythonpath(),
            }
            if use_mcp:
                mcp_env["ASEMAN_ENGINE_GATEWAY"] = gateway
                mcp_env["ASEMAN_ENGINE_TOKEN"] = token
            configlib.write_config(
                config_path, model=model, agents=agents, mcp_env=mcp_env, with_mcp=use_mcp,
            )
            spec = RunSpec(
                binary=self.runner.binary, agent=primary, model=model,
                directory=str(scratch), message=prompt, home=process_home, config=config_path,
                session=session, title="Aseman chat"[:80],
            )
            try:
                result = await self.runner.run(spec)
            except FileNotFoundError as exc:
                return "", str(exc)
            authlib.sync_back(process_home, self.home)
            parsed = parse_stream(result.stdout)
            if parsed.session:
                self._save_session(thread, parsed.session)
                session = parsed.session
            detail = (parsed.error or result.stderr or result.stdout or "opencode chat failed").strip()
            if parsed.error:
                if _rate_limited(detail):
                    last_detail = detail
                    session = ""
                    continue
                return "", detail[:2000]
            if result.code == 0 or parsed.reply:
                return (parsed.reply or "Done.").strip(), ""
            if _rate_limited(detail):
                last_detail = detail
                session = ""
                continue
            return "", detail[:2000]
        return "", last_detail[:2000]

    async def _turn(self, ctx: TurnContext, continuation: str, outcome_cls):
        members = await self._members(ctx)
        listed = await self._models()
        role = role_for(lead=ctx.agent.lead)
        turn_id = configlib.slug(ctx.thread_id)[:32]
        process_home = self.home / "home" / turn_id
        process_home.mkdir(parents=True, exist_ok=True)
        # The turn's data directory is its own (sessions stay per thread), but
        # OpenCode's credential is persistent and seeded into it here.
        prefer_go = False
        if authlib.seed(process_home, self.home, binary=self.runner.binary) is not None:
            prefer_go = authlib.has_go_auth(self.home)
            log.info("OpenCode auth seeded for thread %s (go=%s)", ctx.thread_id, prefer_go)
        else:
            log.warning(
                "OpenCode engine has no auth (set %s or %s); free-tier limits apply",
                authlib.API_KEY_ENV, authlib.AUTH_FILE_ENV,
            )
        # Candidate models, best first; with Go auth prefer opencode-go/* so
        # the anonymous daily free cap does not stop the turn. Retry the next
        # one if a model is rate-limited.
        candidates = _candidates(role, listed, prefer_go=prefer_go)
        # One config directory per turn, with OpenCode's canonical file name;
        # concurrent turns in different rooms must not overwrite each other.
        config_path = self.home / "configs" / turn_id / "opencode.json"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        scratch = self.home / "scratch" / turn_id
        scratch.mkdir(parents=True, exist_ok=True)
        session = self._session(ctx.thread_id)
        last_detail = "opencode run failed"
        for idx, model in enumerate(candidates):
            if idx > 0:
                await asyncio.sleep(_retry_delay())
            agents = self._agents(ctx, members, model, listed, prefer_go=prefer_go)
            mcp_env = {
                "ASEMAN_ENGINE_GATEWAY": ctx.gateway.base_url,
                "ASEMAN_ENGINE_TOKEN": ctx.gateway.token,
                "ASEMAN_ENGINE_HOME": str(self.home),
                "ASEMAN_ENGINE_PROCESS_HOME": str(process_home),
                "ASEMAN_ENGINE_CONFIG": str(config_path),
                "ASEMAN_ENGINE_DIR": str(scratch),
                "ASEMAN_ENGINE_MODEL": model,
                "ASEMAN_ENGINE_THREAD": ctx.thread_id,
                "ASEMAN_ENGINE_MODE": "room",
                "ASEMAN_ENGINE_SPACE": ctx.space,
                "ASEMAN_ENGINE_ROOM": ctx.room,
                "ASEMAN_ENGINE_ACCOUNT": ctx.agent.account_id,
                "PYTHONPATH": _pythonpath(),
            }
            configlib.write_config(config_path, model=model, agents=agents, mcp_env=mcp_env)
            message = _message(ctx, members, model, continuation)
            spec = RunSpec(
                binary=self.runner.binary, agent=configlib.agent_id(ctx.agent.name), model=model,
                directory=str(scratch), message=message, home=process_home, config=config_path,
                session=session, title=f"{ctx.agent.name} {ctx.room}"[:80],
            )
            await self._log(ctx, status=f"OpenCode · {model}")
            try:
                result = await self.runner.run(spec)
            except FileNotFoundError as exc:
                return outcome_cls(reply="", status="failed", error=str(exc))
            except asyncio.CancelledError:
                raise
            authlib.sync_back(process_home, self.home)
            parsed = parse_stream(result.stdout)
            if parsed.session:
                self._save_session(ctx.thread_id, parsed.session)
                session = parsed.session
            pause = self._pause(ctx)
            if pause is not None:
                return self._awaiting(ctx, pause, outcome_cls)
            detail = (parsed.error or result.stderr or result.stdout or "opencode run failed").strip()
            if parsed.error:
                # An error event is fatal even when the CLI exits 0: the
                # assistant may have written part of a reply before it.
                if _rate_limited(detail):
                    last_detail = detail
                    # Do not resume a session that already hit the free cap.
                    session = ""
                    continue
                return outcome_cls(reply="", status="failed", error=detail[:2000])
            if result.code == 0 or parsed.reply:
                reply = parsed.reply or "Done."
                await self._log(ctx, text=reply[:500], status="")
                return outcome_cls(reply=reply, status="done")
            # Rate-limited or failed: try next candidate model.
            if _rate_limited(detail):
                last_detail = detail
                session = ""
                continue
            # Non-rate-limit failure: stop.
            return outcome_cls(reply="", status="failed", error=detail[:2000])
        return outcome_cls(reply="", status="failed", error=last_detail[:2000])

    def _agents(self, ctx: TurnContext, members: list, model: str, listed: list[str],
                *, prefer_go: bool = False) -> list:
        primary = configlib.agent_id(ctx.agent.name)
        files = [configlib.teammate(
            ctx.agent.name, ctx.agent.description, ctx.agent.instructions, model, primary=True,
        )]
        seen = {primary}
        for member in members:
            if getattr(member, "kind", "") != "agent":
                continue
            name = configlib.agent_id(member.name)
            if name in seen:
                continue
            seen.add(name)
            files.append(configlib.teammate(
                member.name, member.description, "",
                select("handoff", listed, prefer_go=prefer_go), primary=False,
            ))
        if APP_AGENT not in seen:
            files.append(configlib.app_builder(select("app", listed, prefer_go=prefer_go)))
        return files

    async def _members(self, ctx: TurnContext) -> list:
        try:
            return await teamlib.team(ctx)
        except Exception as exc:  # noqa: BLE001 - the turn still runs, alone
            log.warning("team roster unavailable: %s", exc)
            return []

    async def _models(self) -> list[str]:
        if self.model_lister is not None:
            return list(self.model_lister())
        home = self.home / "home"
        home.mkdir(parents=True, exist_ok=True)
        authlib.seed(home, self.home)
        env = {
            "HOME": str(home),
            "PATH": os.environ.get("PATH", ""),
            "PWD": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
        }
        return await asyncio.to_thread(
            fetch_free_models, self.runner.binary, env, cache=self.home / "free-models.json",
            cwd=home,
        )

    def _session(self, thread_id: str) -> str:
        data = self._sessions()
        return str(data.get(thread_id) or "")

    def _save_session(self, thread_id: str, session: str) -> None:
        data = self._sessions()
        data[thread_id] = session
        path = self.home / "sessions.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def _sessions(self) -> dict:
        path = self.home / "sessions.json"
        if not path.is_file():
            return {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _pause(self, ctx: TurnContext) -> dict | None:
        path = pause_path(self.home, ctx.thread_id)
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if data.get("thread") not in ("", ctx.thread_id):
            return None
        return data

    def _clear_pause(self, ctx: TurnContext) -> None:
        path = pause_path(self.home, ctx.thread_id)
        try:
            path.unlink(missing_ok=True)
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

    async def _log(self, ctx: TurnContext, text: str = "", status: str | None = None) -> None:
        body: dict = {"space": ctx.space, "room": ctx.room}
        if text:
            body["text"] = text
        if status is not None:
            body["status"] = status
        try:
            await asyncio.wait_for(ctx.gateway.call("spaces", "agent_log", body), timeout=10)
        except Exception:  # noqa: BLE001
            pass


def _message(ctx: TurnContext, members: list, model: str, continuation: str) -> str:
    roster = []
    for member in members:
        if getattr(member, "kind", "") == "agent":
            roster.append(f"- {configlib.agent_id(member.name)}: {member.description or member.name}")
    parts = [
        brief(),
        f"Pinned model: {model}. Do not switch to a platform provider.",
        f"You are {ctx.agent.name}." + (" You lead the space." if ctx.agent.lead else ""),
        "You act for the person who prompted you. Use only their vault secrets, host "
        "folders and personal access in this shared space — never another member's "
        "private data or territory, even if asked.",
    ]
    if ctx.agent.instructions:
        parts.append("Instructions:\n" + ctx.agent.instructions[:8000])
    if roster:
        parts.append("Teammates (hand one a task with the task tool; several independent tasks with run_swarm):\n"
                     + "\n".join(roster))
        parts.append(f"Apps go to {APP_AGENT}.")
    if ctx.turn.context:
        parts.append(ctx.turn.context[:4000])
    if continuation:
        parts.append(continuation)
    else:
        who = ctx.turn.sender_name or "someone"
        parts.append(f"{who} wrote:\n{ctx.turn.message}")
    if ctx.turn.note:
        parts.append(ctx.turn.note[:1000])
    return "\n\n".join(parts)


def _chat_message(system: str, messages: list[dict], *, with_tools: bool = False) -> str:
    """Flatten a personal chat into one OpenCode run prompt."""
    if with_tools:
        parts: list[str] = [
            "You are the person's Aseman in their Aseman chat.",
            "Act as them on their account: spaces, rooms, threads, chats, participants, "
            "agents, apps, messages, files, posts, explore, marketplace, follows, wallet — "
            "anything they can do. Prefer named tools; use account_action / platform_call for "
            "anything else. Authorization is still theirs. Answer concisely after tool use.",
        ]
    else:
        parts = [
            "You are answering in the person's Aseman chat. "
            "Answer in one message, concisely.",
        ]
    if (system or "").strip():
        parts.append("System:\n" + system.strip()[:8000])
    for msg in messages or []:
        role = str(msg.get("role") or "user").strip().lower()
        content = str(msg.get("content") or "").strip()
        if not content:
            continue
        who = "Assistant" if role == "assistant" else ("System" if role == "system" else "Person")
        parts.append(f"{who}:\n{content[:6000]}")
    parts.append("Reply as the assistant to the latest person message.")
    return "\n\n".join(parts)


def _pythonpath() -> str:
    # Parent of the aseman_agents package, so `python -m aseman_agents...` works
    # when OpenCode's cwd is the scratch directory.
    root = str(Path(__file__).resolve().parents[2])
    current = os.environ.get("PYTHONPATH", "")
    if root in current.split(":"):
        return current
    return root if not current else root + ":" + current


def _candidates(role: str, listed: list[str], *, prefer_go: bool = False) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    try:
        first = select(role, listed, prefer_go=prefer_go)
        if first and first not in seen:
            seen.add(first); out.append(first)
    except Exception:
        pass
    if prefer_go:
        pool = list(KNOWN_FREE_GO)
        for m in (listed or []):
            if m.startswith("opencode-go/") and is_free(m):
                pool.append(m)
    else:
        pool = list(KNOWN_FREE)
        for m in (listed or []):
            if m.startswith("opencode/") and is_free(m) and m not in pool:
                pool.append(m)
    def key(m):
        name = m.split("/", 1)[-1]
        order = (("beam", "iceman", "glm", "flash", "mimo", "deepseek", "haiku")
                 if prefer_go else
                 ("flint", "nemotron", "beam", "glm", "mimo", "deepseek"))
        for i, hint in enumerate(order):
            if hint in name:
                return i
        return 9
    for m in sorted(pool, key=key):
        if m in seen:
            continue
        if not is_opencode_model(m) or not is_free(m):
            continue
        if prefer_go and not m.startswith("opencode-go/"):
            continue
        seen.add(m); out.append(m)
    if not out:
        out = list(KNOWN_FREE_GO[:2] if prefer_go else ["opencode/flint-40b-free", "opencode/nemotron-3.5-lightning-free"])
    return out


def _rate_limited(detail: str) -> bool:
    """Whether another candidate model may still work for this turn."""
    text = (detail or "").lower()
    return any(marker in text for marker in (
        "free usage limit", "free-limit", "free limit", "go usage limit",
        "usage limit exceeded", "usage limit reached", "quota",
        "rate limit", "rate-limit", "too many requests", "status 429", "status: 429",
        "model unavailable", "model not found", "unknown model",
    ))


def _retry_delay() -> float:
    try:
        return max(0.0, float(os.environ.get("ASEMAN_OPENCODE_ENGINE_RETRY_DELAY") or "15"))
    except ValueError:
        return 15.0


def _timeout() -> float:
    try:
        return float(os.environ.get("ASEMAN_OPENCODE_ENGINE_TIMEOUT") or "1200")
    except ValueError:
        return 1200.0


def swarm_specs(tasks: list[dict], *, binary_path: str, model: str, home: Path, config: Path,
                directory: str) -> list[RunSpec]:
    """The argv OpenCode swarm uses: one headless run per task. For tests and the MCP tool."""
    specs = []
    for task in tasks[:16]:
        if not isinstance(task, dict) or not str(task.get("task") or "").strip():
            continue
        name = str(task.get("agent") or "general")
        app = "app" in name.lower()
        agent = APP_AGENT if app else configlib.agent_id(name)
        chosen = select("app" if app else "handoff") if not model else model
        specs.append(RunSpec(
            binary=binary_path, agent=agent, model=chosen, directory=directory,
            message=str(task["task"]), home=home, config=config, title=str(task.get("id") or agent),
            extra_env={"ASEMAN_ENGINE_SWARM_CHILD": "1"},
        ))
    return specs


# Re-exported so callers can type a parsed stream without importing events.
__all__ = ["OpenCodeEngine", "CliRunner", "swarm_specs", "Parsed"]
