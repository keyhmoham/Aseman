"""Each agent thread as an OpenCode project.

A thread (an agent in a room, or a restricted request, or a parallel
instance) is an OpenCode project directory under the runtime's data volume,
with an ``opencode.json`` the runtime writes:

* the one provider, ``tradera``: the relay to the node for this project
  (relay.py), whatever model the admin configured for the agent — the model's
  window and output limit are given so OpenCode compacts the conversation in
  time;
* the one MCP server, ``tradera``: the agent's tools (mcp.py);
* the agent ``tradera``: every tool but the runtime's denied, OpenCode's
  ``skill`` and ``task`` tools on when the agent's harness has skills or
  subagents (harness/), and a step limit above the turn's call budget;
* the agent's harness: its skills, subagents and (when the node allows them)
  plugins, the parts of the agent that improve as it works.

The project directory holds nothing of the space's work: agents work in the
space's shared sandbox through their tools.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..context import AgentDef
from . import convert

#: The window assumed for a model nobody told the runtime about.
DEFAULT_WINDOW = 128_000
DEFAULT_OUTPUT = 16_384
PLUGIN = Path(__file__).resolve().parent / "plugin" / "tradera.ts"
SCHEMA = "https://opencode.ai/config.json"


@dataclass
class HarnessFiles:
    """The OpenCode-native parts of an agent's harness (harness/store.py)."""

    skills: dict[str, str] = field(default_factory=dict)  # name → SKILL.md
    skill_files: dict[str, str] = field(default_factory=dict)  # skills/<name>/scripts/... → text
    subagents: dict[str, dict[str, Any]] = field(default_factory=dict)  # name → {description, prompt}
    plugins: dict[str, str] = field(default_factory=dict)  # name → plugin/<name>.ts source


def project_key(base_thread: str) -> str:
    return hashlib.sha256(base_thread.encode()).hexdigest()[:24]


def window(agent: AgentDef) -> int:
    if agent.context_window > 0:
        return agent.context_window
    try:
        return int(os.environ.get("TRADERA_DEFAULT_CONTEXT_WINDOW", "") or DEFAULT_WINDOW)
    except ValueError:
        return DEFAULT_WINDOW


class Projects:
    """The project directories and their configs."""

    def __init__(self, root: str | Path, callback_url: str, token: Any) -> None:
        self.root = Path(root)
        self.callback_url = callback_url.rstrip("/")
        self.token = token  # key → credential (runs.Registry.token)
        self._written: dict[str, str] = {}

    def directory(self, key: str) -> Path:
        return self.root / key

    def config(self, key: str, agent: AgentDef, *, steps: int, harness: HarnessFiles | None = None,
               plugins: bool = False) -> dict[str, Any]:
        directory = self.directory(key)
        token = self.token(key)
        harness = harness or HarnessFiles()
        permission: dict[str, Any] = {"*": "deny", convert.PREFIX + "*": "allow", "doom_loop": "allow",
                                      "external_directory": "deny", "question": "deny"}
        if harness.skills:
            permission["skill"] = "allow"
        if harness.subagents:
            permission["task"] = "allow"
        model: dict[str, Any] = {"name": agent.model or "agent", "tool_call": True, "attachment": True,
                                 "temperature": True, "reasoning": bool(agent.reasoning_effort),
                                 "limit": {"context": window(agent), "output": agent.max_tokens or DEFAULT_OUTPUT}}
        agents: dict[str, Any] = {"tradera": {"mode": "primary", "prompt": "", "steps": steps,
                                              "permission": permission, "description": agent.description[:200]}}
        for name, sub in harness.subagents.items():
            agents[name] = {"mode": "subagent", "description": str(sub.get("description") or name)[:500],
                            "prompt": str(sub.get("prompt") or ""), "steps": max(5, steps // 3),
                            "permission": {k: v for k, v in permission.items() if k != "task"}}
        plugin_files = [PLUGIN.as_uri()]
        if plugins:
            plugin_files += [(directory / "harness" / "plugin" / f"{name}.ts").as_uri() for name in sorted(harness.plugins)]
        return {
            "$schema": SCHEMA,
            "autoupdate": False, "share": "disabled", "snapshot": False, "lsp": False, "formatter": False,
            "enabled_providers": ["tradera"],
            "model": "tradera/agent", "small_model": "tradera/agent",
            "default_agent": "tradera",
            "provider": {"tradera": {
                "npm": "@ai-sdk/openai-compatible", "name": "Tradera",
                "options": {"baseURL": f"{self.callback_url}/opencode/llm/{key}/v1", "apiKey": token,
                            "timeout": False},
                "models": {"agent": model}}},
            "mcp": {convert.MCP_SERVER: {"type": "remote", "url": f"{self.callback_url}/opencode/mcp/{key}",
                                         "headers": {"Authorization": f"Bearer {token}"}, "oauth": False,
                                         "timeout": 3_600_000}},
            "agent": agents,
            "plugin": plugin_files,
            "skills": {"paths": [str(directory / "harness" / "skills")]} if harness.skills else {},
            "compaction": {"auto": True, "prune": True},
            "experimental": {"mcp_timeout": 3_600_000},
        }

    def ensure(self, key: str, agent: AgentDef, *, steps: int, harness: HarnessFiles | None = None,
               plugins: bool = False) -> tuple[str, bool]:
        """The project's directory, written as the turn needs it; True when its
        config changed (OpenCode must load it again)."""
        directory = self.directory(key)
        harness = harness or HarnessFiles()
        config = self.config(key, agent, steps=steps, harness=harness, plugins=plugins)
        files: dict[str, str] = {"opencode.json": json.dumps(config, indent=2, sort_keys=True)}
        for name, body in harness.skills.items():
            files[f"harness/skills/{name}/SKILL.md"] = body
        for rel, body in harness.skill_files.items():
            files[f"harness/{rel}"] = body
        if plugins:
            for name, body in harness.plugins.items():
                files[f"harness/plugin/{name}.ts"] = body
        digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
        if self._written.get(key) == digest and (directory / "opencode.json").is_file():
            return str(directory), False
        on_disk = (directory / "opencode.json").read_text() if (directory / "opencode.json").is_file() else None
        shutil.rmtree(directory / "harness", ignore_errors=True)
        directory.mkdir(parents=True, exist_ok=True)
        for rel, body in files.items():
            path = directory / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
        changed = self._written.get(key) is not None or (on_disk is not None and on_disk != files["opencode.json"])
        self._written[key] = digest
        return str(directory), changed
