"""harness2's editing stages as OpenCode sessions.

harness2 runs its harness editor, composer and experience reflector as
OpenCode sessions over a directory of evidence (``context/``), and so does the
runtime: each stage is a session in a scratch OpenCode project whose only
tools are OpenCode's own file tools inside that project (no shell: the
evidence and candidate harnesses are read, never run). Its model calls go
through the relay to the node's learn endpoint, which uses the agent's own
model and bills the agent's project for its learning.
"""

from __future__ import annotations

import hashlib
import json
import logging
import shutil
import time
from pathlib import Path
from typing import Any


from ..opencode.engine import final_text
from ..opencode.runs import EditorRun
from ..opencode.workspace import PLUGIN, SCHEMA

log = logging.getLogger("tradera.agents.harness")

#: Model calls one editing session may make.
EDITOR_STEPS = 40
ASK = "Do the job your instructions describe. Your evidence is on disk under ./context/: read it first."


class Editor:
    def __init__(self, engine: Any, root: Path, *, node_url: str, secret: str, client: Any) -> None:
        self.engine = engine
        self.root = Path(root)
        self.node_url = node_url
        self.secret = secret
        self.client = client

    def config(self, key: str) -> dict[str, Any]:
        token = self.engine.registry.token(key)
        tools = {"read": "allow", "edit": "allow", "glob": "allow", "grep": "allow", "list": "allow"}
        return {
            "$schema": SCHEMA, "autoupdate": False, "share": "disabled", "snapshot": False, "lsp": False,
            "formatter": False, "enabled_providers": ["tradera"], "model": "tradera/agent",
            "small_model": "tradera/agent", "default_agent": "editor",
            "provider": {"tradera": {"npm": "@ai-sdk/openai-compatible", "name": "Tradera",
                                     "options": {"baseURL": f"{self.engine.projects.callback_url}/opencode/llm/{key}/v1",
                                                 "apiKey": token, "timeout": False},
                                     "models": {"agent": {"name": "agent", "tool_call": True,
                                                          "limit": {"context": 128_000, "output": 16_384}}}}},
            "agent": {"editor": {"mode": "primary", "prompt": "", "steps": EDITOR_STEPS,
                                 "permission": {"*": "deny", **tools, "external_directory": "deny",
                                                "doom_loop": "allow", "question": "deny"}}},
            "plugin": [PLUGIN.as_uri()],
            # No automatic compaction: OpenCode would make the editor "continue" after it.
            "compaction": {"auto": False, "prune": True},
        }

    async def session(self, workdir: Path, mission: str, *, space: str, agent_vm: str, label: str) -> str:
        """Run one editing stage over ``workdir/context``; its final answer."""
        key = "ed" + hashlib.sha256(f"{workdir}:{time.time()}".encode()).hexdigest()[:22]
        workdir.mkdir(parents=True, exist_ok=True)
        (workdir / "opencode.json").write_text(json.dumps(self.config(key), indent=2))
        run = EditorRun(key=key, node_url=self.node_url, secret=self.secret, space=space, agent_vm=agent_vm,
                        system=mission, client=self.client, budget=EDITOR_STEPS)
        server = self.engine.server
        self.engine.registry.add(run)
        try:
            sid = await server.create_session(str(workdir), label)
            run.root_session = sid
            out = await server.prompt(str(workdir), sid, parts=[{"type": "text", "text": ASK}], agent="editor")
            error = (out.get("info") or {}).get("error")
            if error:
                log.warning("harness %s failed: %s", label, error)
                return ""
            return final_text(out.get("parts") or [])
        finally:
            self.engine.registry.remove(run)
            await server.dispose(str(workdir))


def copy_dir(src: Path, dst: Path) -> None:
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True)



