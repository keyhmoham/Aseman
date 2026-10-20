"""The OpenCode engine: every agent's backbone is a self-hosted OpenCode.

* server.py — the ``opencode serve`` the runtime runs (or reaches) and its API;
* workspace.py — each agent thread as an OpenCode project and its config;
* relay.py — OpenCode's model provider: the node's metered LLM endpoint of the
  turn, through the turn guard and the decision model;
* mcp.py — the agent's tools as an MCP server;
* runs.py — what the runtime knows of each project while OpenCode works on it;
* engine.py — a turn on OpenCode, with human in the loop, overflow recovery,
  completion checks and the agent's harness.

``TRADERA_AGENT_ENGINE=deepagents`` runs agents as LangChain deep agents
instead (the runtime's previous engine), with the same tools and behaviour.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .engine import OpenCodeEngine
from .runs import Registry
from .server import OpenCodeServer
from .workspace import Projects


def enabled() -> bool:
    return os.environ.get("TRADERA_AGENT_ENGINE", "opencode").strip().lower() != "deepagents"


def build(data_dir: str | Path, secret: str, *, callback_url: str, harness: Any = None,
          server: OpenCodeServer | None = None) -> OpenCodeEngine:
    registry = Registry(secret)
    projects = Projects(Path(data_dir) / "opencode" / "projects", callback_url, registry.token)
    return OpenCodeEngine(server or OpenCodeServer.from_env(data_dir), registry, projects, harness=harness)


__all__ = ["OpenCodeEngine", "OpenCodeServer", "Registry", "Projects", "build", "enabled"]
