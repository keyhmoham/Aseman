"""The Aseman patch overlay for DeepSeek Harness's headless profile.

dsh composes a profile from ordered patch layers: each row is addressed by
its id, and a row's ``config`` is replaced as a whole. The engine writes one
overlay per turn (JSON, which is YAML) and passes it with ``--patch``, so a
roster, model or memory change is what the next process sees and concurrent
turns never share a file.

What the overlay mounts into the harness:

* the LLM route: ``llm-pi-ai`` with an ``aseman`` route on the turn gateway's
  OpenAI-compatible ``/llm`` (the agent's own provider and model, metered on
  the turn), or ``llm-deepseek`` with the engine's own DeepSeek key;
* ``agent-default-model`` pinned to that route;
* the ``aseman`` MCP server (``mcp-client``, stdio): the bridge to the space;
* the harness's own memory: the ``aseman-memory`` plugin (plugins/) over a
  per-space, per-agent store on the engine's disk, whose notes dsh's own
  ``agent-instructions`` loader puts in context every turn;
* the persona (``system-prompt``): the agent, its team and the mechanism map;
* the harness's own swarm: subagents (in-process children), Agent Teams for
  leads with teammates (the profile's ``agent-team`` row, or dsh 0.2.2's
  experimental Agent Teams packages, mounted here) and the workflow tool;
* the runtime's own shell, files, web and plugin manager off: the space's
  computer and apps are reached through the bridge, and plugins are Aseman
  apps (create_plugin), not packages installed into the shared runtime.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

from .cli import TOKEN_ENV

# Gateway route (platform models) or the engine's own DeepSeek key.
LLM_GATEWAY = "gateway"
LLM_DEEPSEEK = "deepseek"

GATEWAY_ROUTE = "aseman"
DEEPSEEK_ROUTE = "deepseek-official"
GATEWAY_MODEL = "aseman/default"

# Rows of the shipped profile the engine turns off.
DISABLED = (
    # The runtime container is not the space's computer, and the turn token
    # sits in the bridge's environment: no shell or files on it.
    "tool-bash", "tool-pwsh", "tool-fs", "tool-fs-search",
    # Plugins are Aseman apps; the shared runtime is never modified by a turn.
    "tool-plugin-manager",
)
WEB_ROWS = ("web", "web-search-deepseek", "web-deepseek-api", "web-fetch-http", "tool-web")


def llm_mode() -> str:
    """``gateway`` (default) or ``deepseek`` (ASEMAN_DSH_ENGINE_LLM, needs a key)."""
    mode = (os.environ.get("ASEMAN_DSH_ENGINE_LLM") or "").strip().lower()
    if mode == LLM_DEEPSEEK and deepseek_key():
        return LLM_DEEPSEEK
    return LLM_GATEWAY


def deepseek_key() -> str:
    return (os.environ.get("ASEMAN_DSH_ENGINE_API_KEY") or "").strip()


def deepseek_model(*, lead: bool) -> str:
    override = (os.environ.get("ASEMAN_DSH_ENGINE_MODEL") or "").strip()
    if override:
        return override
    return "deepseek-v4-pro" if lead else "deepseek-flash"


def web_enabled() -> bool:
    """dsh's web tools search through the DeepSeek Search API: only with a key."""
    return (os.environ.get("ASEMAN_DSH_ENGINE_WEB") or "").strip() == "1" and bool(deepseek_key())


@dataclass
class Overlay:
    """Everything one turn's patch carries."""

    persona: str
    mcp_env: dict[str, str]
    gateway: str = ""
    model: str = ""
    context_window: int = 0
    max_tokens: int = 0
    reasoning_effort: str = ""
    lead: bool = False
    team: bool = False
    # How this dsh ships Agent Teams: "builtin" (a profile row), "experimental"
    # (packages the overlay mounts, dsh 0.2.2-alpha) or "" (none).
    teams: str = ""
    mode: str = LLM_GATEWAY
    with_mcp: bool = True
    extra_disabled: list[str] = field(default_factory=list)
    # The harness's memory: the space's store and this agent's directory in it
    # (the run's working directory). Empty: the run keeps no memory.
    memory_root: str = ""
    memory_agent: str = ""
    agent_name: str = ""


def available_rows(binary: str, home: Path) -> set[str] | None:
    """The row ids the installed dsh's headless profile composes, or None.

    Rows differ between dsh releases (Agent Teams ships in the 0.2.2 line,
    for one) and a patch naming a row the profile lacks is refused, so the
    overlay only addresses rows that exist. Read once per dsh version.
    """
    import subprocess
    home.mkdir(parents=True, exist_ok=True)
    env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "DSH_HOME": str(home / "dsh")}
    try:
        version = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=60,
                                 env=env, check=False).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not version:
        return None
    cache = home / f"rows-{version}.json"
    if cache.is_file():
        try:
            return set(json.loads(cache.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            pass
    try:
        done = subprocess.run([binary, "--profile", "headless", "--dump-default-config"], capture_output=True,
                              text=True, timeout=120, env=env, cwd=str(home), check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    import re
    ids = sorted(set(re.findall(r"^\s*-?\s*id:\s*([A-Za-z0-9_.-]+)\s*$", done.stdout, re.M)))
    if done.returncode != 0 or not ids:
        return None
    home.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(ids), encoding="utf-8")
    return set(ids)


def headless_flags(binary: str, home: Path) -> set[str]:
    """The long options ``dsh --profile headless`` takes (e.g. --approval-policy, 0.2.2+)."""
    import re
    import subprocess
    home.mkdir(parents=True, exist_ok=True)
    env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "DSH_HOME": str(home / "dsh")}
    try:
        done = subprocess.run([binary, "--profile", "headless", "--help"], capture_output=True, text=True,
                              timeout=60, env=env, cwd=str(home), check=False)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return set(re.findall(r"(--[a-z][a-z-]+)", done.stdout))


def build(overlay: Overlay, available: set[str] | None = None) -> list[dict]:
    """The patch rows (a dsh patch list) for one run.

    ``available``: the row ids the installed profile has (available_rows);
    rows it lacks are left out. None addresses every row.
    """
    rows = _build(overlay)
    if available is None:
        return rows
    return [r for r in rows if "insert" in r or r.get("id") in available]


def _build(overlay: Overlay) -> list[dict]:
    rows: list[dict] = []
    if overlay.mode == LLM_DEEPSEEK:
        model = overlay.model or deepseek_model(lead=overlay.lead)
        rows.append({"id": "agent-default-model", "config": _default_model(DEEPSEEK_ROUTE, model, overlay)})
        rows.append({"id": "llm-pi-ai", "disabled": True})
    else:
        if not overlay.gateway:
            raise ValueError("the gateway LLM route needs the turn gateway")
        model = overlay.model or GATEWAY_MODEL
        rows.append({"id": "llm-pi-ai", "config": {"providers": {GATEWAY_ROUTE: _gateway_route(overlay, model)}}})
        rows.append({"id": "agent-default-model", "config": _default_model(GATEWAY_ROUTE, model, overlay)})
        # The node's DeepSeek account route would look for a key it does not have.
        rows.append({"id": "llm-deepseek", "disabled": True})
    rows.append({"id": "system-prompt", "config": {"personaPrefix": overlay.persona}})
    if overlay.teams == TEAMS_BUILTIN:
        rows.append({"id": "agent-team", "config": {"maxTasks": 256, "defaultEnabled": bool(overlay.team)}})
    elif overlay.teams == TEAMS_EXPERIMENTAL and overlay.team:
        # dsh's experimental Agent Teams layer: spawn_teammate and team-scoped
        # list_agents / send_message / interrupt_agent / wait_agent replace the
        # plain subagent tools; workflow keeps fresh children.
        rows += [{"id": row, "disabled": True} for row in TEAM_REPLACES]
        rows.append({"insert": team_rows()})
    if overlay.memory_root:
        # dsh's own instruction loader reads the memory's notes: the space's
        # AGENTS.md (root, marked .aseman-space) and the agent's, in the run's
        # working directory.
        rows.append({"id": "agent-instructions", "config": {
            "maxBytes": 32000, "maxSourceBytes": 262144,
            "projectRootMarkers": [MEMORY_MARKER],
            "instructionFileCandidates": ["AGENTS.md"],
            "localInstructionFileCandidates": [],
        }})
    else:
        rows.append({"id": "agent-instructions", "disabled": True})
    for row in DISABLED:
        rows.append({"id": row, "disabled": True})
    if not web_enabled():
        for row in WEB_ROWS:
            rows.append({"id": row, "disabled": True})
    for row in overlay.extra_disabled:
        rows.append({"id": row, "disabled": True})
    inserts = []
    if overlay.memory_root:
        inserts.append(memory_row(overlay))
    if overlay.with_mcp:
        inserts.append(mcp_row(overlay.mcp_env))
    if inserts:
        rows.append({"insert": inserts})
    return rows


TEAMS_BUILTIN = "builtin"
TEAMS_EXPERIMENTAL = "experimental"
TEAM_PACKAGE = "dsh-experimental-agent-team"
TEAM_REPLACES = ("tool-subagent-control", "tool-subagent", "tool-subagent-fork")


def team_rows() -> list[dict]:
    """dsh 0.2.2's experimental Agent Teams (its profile layer, minus the Web UI)."""
    return [
        {"id": "agent-team", "name": "@deepseek-ai/dsh-experimental-agent-team",
         "config": {"maxMembers": 8, "maxTasks": 256, "maxMessageBytes": 65536, "disposalTimeoutMs": 5000}},
        {"id": "tool-agent-team", "name": "@deepseek-ai/dsh-experimental-tool-agent-team",
         "config": {"freshProvider": "spawn", "forkProvider": "fork"}},
    ]


def teams_kind(binary: str, rows: set[str] | None) -> str:
    """How the installed dsh ships Agent Teams (TEAMS_BUILTIN / TEAMS_EXPERIMENTAL / "")."""
    if rows is None:
        return TEAMS_BUILTIN
    if "agent-team" in rows and "tool-agent-team" in rows:
        return TEAMS_BUILTIN
    return TEAMS_EXPERIMENTAL if experimental_teams(binary) else ""


def experimental_teams(binary: str) -> bool:
    """Whether dsh's experimental Agent Teams packages are installed beside it."""
    import shutil
    found = shutil.which(binary) or binary
    try:
        path = Path(found).resolve()
    except OSError:
        return False
    # .../@deepseek-ai/dsh/lib/bin.js: the packages are its dependencies,
    # nested (npm --global) or hoisted beside it (a project install).
    for parent in path.parents:
        if parent.name == "dsh" and parent.parent.name == "@deepseek-ai":
            return any((base / "@deepseek-ai" / TEAM_PACKAGE / "package.json").is_file()
                       for base in (parent / "node_modules", parent.parent.parent))
    return False


MEMORY_MARKER = ".aseman-space"
MEMORY_PLUGIN = Path(__file__).resolve().parent / "plugins" / "aseman-memory.mjs"


def memory_row(overlay: Overlay) -> dict:
    """The harness's own memory plugin, loaded by path."""
    return {
        "id": "aseman-memory",
        "name": str(MEMORY_PLUGIN),
        "config": {
            "root": overlay.memory_root,
            "agent": overlay.memory_agent or "agent",
            "agentName": overlay.agent_name or overlay.memory_agent or "agent",
            "journal": True,
        },
    }


def mcp_row(env: dict[str, str]) -> dict:
    return {
        "id": "aseman-mcp",
        "name": "@deepseek-ai/dsh-mcp-client",
        "config": {
            "transport": "stdio",
            "serverName": "aseman",
            "command": sys.executable,
            "args": ["-m", "aseman_agents.deepseek_engine.mcp_server"],
            "env": dict(env),
            "cwd": env.get("ASEMAN_ENGINE_DIR") or str(Path.cwd()),
            # A hand-off or a swarm waits on other agents' turns.
            "toolCallTimeoutMs": _tool_timeout_ms(),
            "startupTimeoutMs": 60000,
            "closeTimeoutMs": 5000,
            "expandTemplates": False,
            "failOnStartupError": True,
        },
    }


def write(path: Path, overlay: Overlay, available: set[str] | None = None) -> list[dict]:
    rows = build(overlay, available)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# Aseman agentic engine overlay (generated per turn)\n" + json.dumps(rows, indent=2),
                    encoding="utf-8")
    try:
        # The bridge environment carries the turn token.
        os.chmod(path, 0o600)
    except OSError:
        pass
    return rows


def _gateway_route(overlay: Overlay, model: str) -> dict:
    entry: dict = {"id": model, "name": model}
    if overlay.context_window > 0:
        entry["contextWindow"] = overlay.context_window
    if overlay.max_tokens > 0:
        entry["maxTokens"] = overlay.max_tokens
    route: dict = {
        "displayName": "Aseman",
        "api": "openai-completions",
        "baseURL": overlay.gateway.rstrip("/") + "/llm",
        "apiKeyEnv": TOKEN_ENV,
        "models": [entry],
        "defaultContextWindow": overlay.context_window or 128000,
        # The gateway already retries a provider and bills every attempt.
        "retryPolicy": {"mode": "normal", "maxRetries": 2},
    }
    return route


def _default_model(route: str, model: str, overlay: Overlay) -> dict:
    config: dict = {"provider": route, "model": model}
    if overlay.reasoning_effort:
        config["reasoningEffort"] = overlay.reasoning_effort
    return config


def _tool_timeout_ms() -> int:
    try:
        seconds = float(os.environ.get("ASEMAN_DSH_ENGINE_TOOL_TIMEOUT") or "2700")
    except ValueError:
        seconds = 2700.0
    return int(max(30.0, seconds) * 1000)
