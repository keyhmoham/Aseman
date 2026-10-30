"""The engine's OpenCode config.

Written under the engine home on every turn, so a roster or model change is
what the next process sees. The file has no ``aseman`` provider and does not
point at ``/etc/opencode``.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from .mapping import APP_AGENT, brief

_SLUG = re.compile(r"[^a-z0-9-]+")

# Filesystem and network tools stay off: the turn token sits in this config,
# and the space's files are reached through platform_call, not the runtime disk.
DENY = ("bash", "edit", "write", "read", "grep", "glob", "webfetch", "websearch", "skill", "lsp")
ALLOW = ("task", "todowrite")


def slug(name: str) -> str:
    return _SLUG.sub("-", name.lower()).strip("-") or "agent"


def agent_id(name: str) -> str:
    """OpenCode agent name for a platform agent."""
    cleaned = slug(name)
    if cleaned == "aseman-app-builder" or cleaned == APP_AGENT:
        return APP_AGENT
    if cleaned.startswith("aseman-"):
        return cleaned[:48]
    return f"aseman-{cleaned}"[:48]


@dataclass
class AgentFile:
    name: str
    description: str
    mode: str  # primary | subagent
    model: str
    prompt: str


def permission() -> dict[str, str]:
    out = {name: "deny" for name in DENY}
    for name in ALLOW:
        out[name] = "allow"
    return out


def write_config(path: Path, *, model: str, agents: list[AgentFile], mcp_env: dict[str, str]) -> None:
    """Write opencode.json. ``model`` must be a free opencode/* id."""
    if not model.startswith("opencode/") or "aseman" in model:
        raise ValueError(f"refusing to pin OpenCode to {model}")
    doc = {
        "$schema": "https://opencode.ai/config.json",
        "model": model,
        "permission": permission(),
        "agent": {
            agent.name: {
                "description": agent.description,
                "mode": agent.mode,
                "model": agent.model,
                "prompt": agent.prompt,
                "permission": permission(),
            }
            for agent in agents
        },
        "mcp": {
            "aseman-engine": {
                "type": "local",
                "command": [sys.executable, "-m", "aseman_agents.opencode_engine.mcp_server"],
                "environment": mcp_env,
            }
        },
    }
    # No provider block: the built-in OpenCode gateway is the only one.
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    agent_dir = Path(mcp_env["ASEMAN_ENGINE_PROCESS_HOME"]) / ".config" / "opencode" / "agents"
    agent_dir.mkdir(parents=True, exist_ok=True)
    for agent in agents:
        _markdown(agent_dir / f"{agent.name}.md", agent)


def _markdown(path: Path, agent: AgentFile) -> None:
    lines = ["---", f"description: {json.dumps(agent.description)}", f"mode: {agent.mode}",
             f"model: {agent.model}", "permission:"]
    for key, value in permission().items():
        lines.append(f"  {key}: {value}")
    lines += ["---", "", agent.prompt, ""]
    path.write_text("\n".join(lines), encoding="utf-8")


def app_builder(model: str) -> AgentFile:
    return AgentFile(
        name=APP_AGENT,
        description="Builds an app for the space. Not the programmer OpenCode.",
        mode="subagent",
        model=model,
        prompt=(
            "You build the app the lead handed you. Use platform_call for sandbox "
            "files and commands (spaces.tools_list, then spaces.ask). When it runs, "
            "call appui_publish. Do not call opencode_run, appui_create, or aseman-appui. "
            "Do not start a swarm.\n\n" + brief()
        ),
    )


def teammate(name: str, description: str, instructions: str, model: str, *, primary: bool) -> AgentFile:
    body = instructions.strip() or description.strip() or f"You are {name}."
    return AgentFile(
        name=agent_id(name),
        description=(description or f"{name} of the space")[:240],
        mode="primary" if primary else "subagent",
        model=model,
        prompt=(body[:8000] + "\n\n" + brief()),
    )
