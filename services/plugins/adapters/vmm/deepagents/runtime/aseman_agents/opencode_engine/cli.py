"""Headless OpenCode commands, isolated from the programmer install.

The programmer lives in the sandbox: ``/etc/opencode``, ``aseman-appui``,
and the turn's metered ``ASEMAN_LLM_*`` gateway. Every command built here
points at the engine's own config and home, drops those variables, and pins
``--model`` to a free ``opencode/…`` id.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field
from pathlib import Path

# Anything that would send OpenCode at the platform gateway or another
# provider the node happens to have in its environment.
STRIP_ENV = frozenset({
    "ASEMAN_LLM_BASE_URL", "ASEMAN_LLM_API_KEY", "OPENCODE_API_KEY", "OPENCODE_MODEL",
    "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE",
    "ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY",
    "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT",
    "GROQ_API_KEY", "MISTRAL_API_KEY", "TOGETHER_API_KEY", "FIREWORKS_API_KEY",
    "DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN",
    "OPENCODE_CONFIG",
})

PROGRAMMER_CONFIG = "/etc/opencode/opencode.json"


def thread_key(thread_id: str) -> str:
    return hashlib.sha256(thread_id.encode()).hexdigest()[:24]


def pause_path(home: Path, thread_id: str) -> Path:
    return home / "pauses" / f"{thread_key(thread_id)}.json"


def isolated_env(home: Path, config: Path, base: dict[str, str] | None = None,
                 extra: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for one OpenCode process. No platform LLM credentials."""
    src = base if base is not None else dict(os.environ)
    env = {k: v for k, v in src.items() if k not in STRIP_ENV}
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["OPENCODE_CONFIG"] = str(config)
    env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
    env.pop("OPENCODE_MODEL", None)
    env.pop("ASEMAN_LLM_BASE_URL", None)
    env.pop("ASEMAN_LLM_API_KEY", None)
    if extra:
        for key, value in extra.items():
            if key in STRIP_ENV:
                continue
            env[key] = value
    return env


def run_argv(*, binary: str, agent: str, model: str, directory: str, message: str,
             session: str = "", title: str = "") -> list[str]:
    """``opencode run`` for one turn or one swarm task."""
    if not model.startswith("opencode/") or "aseman" in model:
        raise ValueError(f"refusing a non-OpenCode model: {model}")
    cmd = [binary, "run", "--standalone", "--format", "json", "--auto", "--agent", agent, "--model", model]
    if title:
        cmd += ["--title", title[:80]]
    if session:
        cmd += ["--session", session]
    cmd.append(message)
    return cmd


@dataclass
class RunSpec:
    """One headless invocation."""

    binary: str
    agent: str
    model: str
    directory: str
    message: str
    home: Path
    config: Path
    session: str = ""
    title: str = ""
    extra_env: dict[str, str] = field(default_factory=dict)
    base_env: dict[str, str] | None = None

    def argv(self) -> list[str]:
        return run_argv(binary=self.binary, agent=self.agent, model=self.model, directory=self.directory,
                        message=self.message, session=self.session, title=self.title)

    def env(self) -> dict[str, str]:
        return isolated_env(self.home, self.config, self.base_env, self.extra_env)


@dataclass
class RunResult:
    stdout: str
    stderr: str
    code: int
