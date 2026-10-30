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
from . import config as configlib
from .cli import RunResult, RunSpec, pause_path
from .events import Parsed, parse_stream
from .mapping import APP_AGENT, brief
from .models import binary, fetch_free_models, is_free, KNOWN_FREE, role_for, select

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

    async def _turn(self, ctx: TurnContext, continuation: str, outcome_cls):
        members = await self._members(ctx)
        listed = await self._models()
        role = role_for(lead=ctx.agent.lead)
        # Candidate models, best first; retry the next one if a model is
        # rate-limited on OpenCode's free tier.
        candidates = _candidates(role, listed)
        turn_id = configlib.slug(ctx.thread_id)[:32]
        process_home = self.home / "home" / turn_id
        process_home.mkdir(parents=True, exist_ok=True)
        config_path = self.home / "configs" / f"{turn_id}.json"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        scratch = self.home / "scratch" / turn_id
        scratch.mkdir(parents=True, exist_ok=True)
        session = self._session(ctx.thread_id)
        message_base = None
        last_detail = "opencode run failed"
        for idx, model in enumerate(candidates):
            agents = self._agents(ctx, members, model, listed)
            mcp_env = {
                "ASEMAN_ENGINE_GATEWAY": ctx.gateway.base_url,
                "ASEMAN_ENGINE_TOKEN": ctx.gateway.token,
                "ASEMAN_ENGINE_HOME": str(self.home),
                "ASEMAN_ENGINE_PROCESS_HOME": str(process_home),
                "ASEMAN_ENGINE_CONFIG": str(config_path),
                "ASEMAN_ENGINE_DIR": str(scratch),
                "ASEMAN_ENGINE_MODEL": model,
                "ASEMAN_ENGINE_THREAD": ctx.thread_id,
                "PYTHONPATH": os.environ.get("PYTHONPATH", ""),
            }
            mcp_env["PYTHONPATH"] = _pythonpath()
            configlib.write_config(config_path, model=model, agents=agents, mcp_env=mcp_env)
            try:
                legacy = self.home / "opencode.json"
                legacy.write_text(config_path.read_text(encoding="utf-8"), encoding="utf-8")
            except Exception:
                pass
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
            parsed = parse_stream(result.stdout)
            if parsed.session:
                self._save_session(ctx.thread_id, parsed.session)
                session = parsed.session
            pause = self._pause(ctx)
            if pause is not None:
                return self._awaiting(ctx, pause, outcome_cls)
            detail = (parsed.error or result.stderr or result.stdout or "opencode run failed").strip()
            if result.code == 0 or parsed.reply:
                reply = parsed.reply or parsed.error or "Done."
                await self._log(ctx, text=reply[:500], status="")
                return outcome_cls(reply=reply, status="done")
            # Rate-limited or failed: try next candidate model.
            if "free usage limit" in detail.lower() or "free-limit" in detail.lower() or "quota" in detail.lower():
                last_detail = detail
                continue
            # Non-rate-limit failure: stop.
            return outcome_cls(reply="", status="failed", error=detail[:2000])
        return outcome_cls(reply="", status="failed", error=last_detail[:2000])

    def _agents(self, ctx: TurnContext, members: list, model: str, listed: list[str]) -> list:
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
                member.name, member.description, "", select("handoff", listed), primary=False,
            ))
        if APP_AGENT not in seen:
            files.append(configlib.app_builder(select("app", listed)))
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
        env = {
            "HOME": str(home),
            "PATH": os.environ.get("PATH", ""),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
        }
        return await asyncio.to_thread(
            fetch_free_models, self.runner.binary, env, cache=self.home / "free-models.json",
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


def _pythonpath() -> str:
    # Parent of the aseman_agents package, so `python -m aseman_agents...` works
    # when OpenCode's cwd is the scratch directory.
    root = str(Path(__file__).resolve().parents[2])
    current = os.environ.get("PYTHONPATH", "")
    if root in current.split(":"):
        return current
    return root if not current else root + ":" + current


def _candidates(role: str, listed: list[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    try:
        first = select(role, listed)
        if first and first not in seen:
            seen.add(first); out.append(first)
    except Exception:
        pass
    pool = [m for m in (listed or []) if m.startswith("opencode/")]
    if not pool:
        pool = list(KNOWN_FREE)
    def key(m):
        for i, hint in enumerate(("flint", "nemotron", "beam", "glm")):
            if hint in m:
                return i
        return 9
    for m in sorted(pool, key=key):
        if m in seen:
            continue
        if not m.startswith("opencode/"):
            continue
        seen.add(m); out.append(m)
    if not out:
        out = ["opencode/flint-40b-free", "opencode/nemotron-3.5-lightning-free"]
    return out


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
