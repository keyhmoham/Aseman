"""Headless DeepSeek Harness commands.

Every run boots the shipped ``headless`` profile under the engine's own
``DSH_HOME`` with the turn's patch overlay (``--patch``), prints
newline-delimited run events (``--json``) and resumes the thread's dsh
Session (``--session-id``). Approvals are never asked: a headless run has
nobody to ask, and the Aseman bridge asks people through ask_user instead.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field
from pathlib import Path

PROFILE = "headless"

# The LLM credential env the patch's route reads per request.
TOKEN_ENV = "ASEMAN_DSH_LLM_TOKEN"

# Credentials the node may have in its environment. The harness gets only what
# the turn's route needs (TOKEN_ENV, or DEEPSEEK_API_KEY in direct mode).
STRIP_ENV = frozenset({
    "ASEMAN_LLM_BASE_URL", "ASEMAN_LLM_API_KEY", "OPENCODE_API_KEY", "OPENCODE_MODEL",
    "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE",
    "ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY",
    "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT",
    "GROQ_API_KEY", "MISTRAL_API_KEY", "TOGETHER_API_KEY", "FIREWORKS_API_KEY",
    "DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN",
    "ASEMAN_OPENCODE_ENGINE_API_KEY", "ASEMAN_DSH_ENGINE_API_KEY",
    "ASEMAN_OPENVIKING_API_KEY", "ASEMAN_RUNTIME_SECRET",
    "DSH_HOME", "DSH_PERMISSION_MODE",
    # The runtime's own source tree is not the turn's workspace.
    "PWD",
})


def default_binary() -> str:
    return os.environ.get("ASEMAN_DSH_BIN") or "dsh"


def thread_key(thread_id: str) -> str:
    return hashlib.sha256(thread_id.encode()).hexdigest()[:24]


def pause_path(home: Path, thread_id: str) -> Path:
    return Path(home) / "pauses" / f"{thread_key(thread_id)}.json"


def isolated_env(home: Path, *, base: dict[str, str] | None = None,
                 extra: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for one dsh process: its own home, no node credentials."""
    src = base if base is not None else dict(os.environ)
    env = {k: v for k, v in src.items() if k not in STRIP_ENV}
    env["DSH_HOME"] = str(home / "dsh")
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["DSH_PERMISSION_MODE"] = "workspace-write"
    # No telemetry leaves the node from an agent turn.
    env["DSH_TELEMETRY_DISABLED"] = "1"
    env["DO_NOT_TRACK"] = "1"
    if extra:
        env.update({k: v for k, v in extra.items() if v is not None})
    return env


def run_argv(*, binary: str, patch: Path, message: str, session: str = "", never_ask: bool = True) -> list[str]:
    """``dsh --profile headless`` for one turn or one swarm task.

    ``never_ask``: pass ``--approval-policy never`` (dsh 0.2.2+ takes it;
    earlier headless builds have no approval prompts to turn off).
    """
    if not message.strip():
        raise ValueError("a dsh run needs a task")
    cmd = [binary, "--profile", PROFILE, "--patch", str(patch), "--json"]
    if never_ask:
        cmd += ["--approval-policy", "never"]
    if session:
        cmd += ["--session-id", session]
    # "-" is dsh's stdin marker; a task that starts with a dash would read as a flag.
    cmd += ["--", message] if message.startswith("-") else [message]
    return cmd


@dataclass
class RunSpec:
    """One headless invocation."""

    binary: str
    patch: Path
    directory: str
    message: str
    home: Path
    session: str = ""
    extra_env: dict[str, str] = field(default_factory=dict)
    base_env: dict[str, str] | None = None
    never_ask: bool = True

    def argv(self) -> list[str]:
        return run_argv(binary=self.binary, patch=self.patch, message=self.message, session=self.session,
                        never_ask=self.never_ask)

    def env(self) -> dict[str, str]:
        env = isolated_env(self.home, base=self.base_env, extra=self.extra_env)
        env["PWD"] = str(self.directory)
        return env


@dataclass
class RunResult:
    stdout: str
    stderr: str
    code: int
