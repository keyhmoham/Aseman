"""Where DeepSeek Harness keeps its own memory, and how Aseman reads it.

The memory belongs to the harness: the ``aseman-memory`` dsh plugin
(plugins/aseman-memory.mjs) writes it and dsh's agent-instructions loader
reads it into every turn. The engine only places it — one store per space,
one directory per agent, the run's working directory — and lets the platform
look at it (the project's notes and an agent's journal).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

NOTES = "AGENTS.md"
MARKER = ".aseman-space"
_SAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def _slug(value: str, fallback: str) -> str:
    clean = _SAFE.sub("-", value or "").strip("-.")
    return clean[:96] or fallback


@dataclass
class Place:
    """One agent's memory in one space."""

    root: Path  # the space's store: shared notes, one directory per agent
    agent: str  # the agent's directory name in it

    @property
    def workdir(self) -> Path:
        path = self.root / self.agent
        path.mkdir(parents=True, exist_ok=True)
        return path


class MemoryStore:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def agent(self, space: str, agent: str) -> Place:
        root = self.root / "spaces" / _slug(space, "default")
        root.mkdir(parents=True, exist_ok=True)
        return Place(root=root, agent=_slug(agent, "agent"))

    def personal(self, account: str) -> Place:
        """A person's Aseman (self-chat / Talk) remembers in a store of its own."""
        root = self.root / "people" / _slug(account, "person")
        root.mkdir(parents=True, exist_ok=True)
        return Place(root=root, agent="aseman")

    # --- what the platform reads -------------------------------------------------

    def view(self, space: str, agent: str = "", *, journal_days: int = 3) -> dict:
        """The space's notes and, for an agent, its notes and latest journal."""
        root = self.root / "spaces" / _slug(space, "default")
        out: dict = {"engine": "deepseek", "space_notes": _read(root / NOTES), "agents": []}
        if root.is_dir():
            out["agents"] = sorted(p.name for p in root.iterdir() if p.is_dir())
        if agent:
            own = root / _slug(agent, "agent")
            days = sorted((own / "journal").glob("*.md"), reverse=True)[:max(0, journal_days)]
            out["agent"] = own.name
            out["notes"] = _read(own / NOTES)
            out["journal"] = [{"day": d.stem, "text": _read(d)} for d in days]
        return out

    def write_notes(self, space: str, content: str, agent: str = "") -> None:
        """People edit the notes too (the project's Memory screen)."""
        place = self.agent(space, agent) if agent else None
        path = (place.workdir if place else self.agent(space, "agent").root) / NOTES
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.strip() + "\n", encoding="utf-8")


def _read(path: Path, limit: int = 200_000) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    return text[-limit:]
