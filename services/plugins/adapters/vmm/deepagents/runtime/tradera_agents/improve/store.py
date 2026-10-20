"""Where an agent's playbook and the turns it learns from live, per space.

    <root>/<space>/<agent>/playbook.json   the playbook: text, version, and every version adopted before
    <root>/<space>/<agent>/system.txt      the agent's system prompt without it (what replays run with)
    <root>/<space>/<agent>/tools.json      the schemas of the tools the agent had (what replays offer it)
    <root>/<space>/<agent>/turns/          the latest turns: what the agent did, how it went, decision points
    <root>/<space>/<agent>/state.json      turns since the last cycle and when it ran

A playbook is per agent and space, like the agent's memory: what an agent
learns in one space never shapes its work in another.
"""

from __future__ import annotations

import json
import re
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

_ID = re.compile(r"[^a-zA-Z0-9_.-]+")
#: Turn records kept per agent and space.
KEEP_TURNS = 30


def _id(value: str) -> str:
    return _ID.sub("-", value).strip("-.")[:80] or "x"


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


@dataclass
class Playbook:
    text: str = ""
    version: int = 0
    score: float = 0.0
    history: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class State:
    turns_since: int = 0
    last_cycle: float = 0.0
    cycles: int = 0


class AgentStore:
    """One agent's learning in one space, on disk."""

    _locks: dict[str, threading.Lock] = {}

    def __init__(self, root: str | Path, space: str, agent: str) -> None:
        self.dir = Path(root) / _id(space) / _id(agent)
        self.lock = self._locks.setdefault(str(self.dir), threading.Lock())

    # --- the playbook --------------------------------------------------------------

    def playbook(self) -> Playbook:
        raw = _read_json(self.dir / "playbook.json")
        if not isinstance(raw, dict):
            return Playbook()
        return Playbook(**{k: v for k, v in raw.items() if k in Playbook.__dataclass_fields__})

    def adopt(self, text: str, *, score: float, baseline: float, evidence: int) -> Playbook:
        """A new playbook version (the one before it stays in its history)."""
        with self.lock:
            book = self.playbook()
            book.history.append({"version": book.version + 1, "text": text, "score": round(score, 4),
                                 "baseline": round(baseline, 4), "evidence": evidence, "adopted_at": time.time()})
            book = Playbook(text=text, version=book.version + 1, score=score, history=book.history[-20:])
            _write(self.dir / "playbook.json", json.dumps(asdict(book), indent=2, ensure_ascii=False))
            return book

    # --- what the agent learns from --------------------------------------------------

    def system(self) -> str:
        try:
            return (self.dir / "system.txt").read_text(encoding="utf-8")
        except OSError:
            return ""

    def record(self, turn: dict[str, Any], system: str) -> None:
        with self.lock:
            turns = self.dir / "turns"
            turns.mkdir(parents=True, exist_ok=True)
            _write(turns / f"{time.time():.6f}.json", json.dumps(turn, ensure_ascii=False, default=str))
            for old in sorted(turns.glob("*.json"))[:-KEEP_TURNS]:
                old.unlink(missing_ok=True)
            if system != self.system():
                _write(self.dir / "system.txt", system)

    def tools(self) -> dict[str, dict[str, Any]]:
        raw = _read_json(self.dir / "tools.json")
        return raw if isinstance(raw, dict) else {}

    def put_tools(self, schemas: dict[str, dict[str, Any]]) -> None:
        """The tools' schemas, merged with the ones known (turns differ in the tools they have)."""
        with self.lock:
            known = self.tools()
            if any(known.get(k) != v for k, v in schemas.items()):
                _write(self.dir / "tools.json", json.dumps({**known, **schemas}, ensure_ascii=False))

    def turns(self, n: int = KEEP_TURNS) -> list[dict[str, Any]]:
        out = []
        for path in sorted((self.dir / "turns").glob("*.json"))[-n:]:
            raw = _read_json(path)
            if isinstance(raw, dict):
                out.append(raw)
        return out

    # --- when to learn ---------------------------------------------------------------

    def state(self) -> State:
        raw = _read_json(self.dir / "state.json")
        if not isinstance(raw, dict):
            return State()
        return State(**{k: v for k, v in raw.items() if k in State.__dataclass_fields__})

    def save(self, state: State) -> None:
        with self.lock:
            _write(self.dir / "state.json", json.dumps(asdict(state)))
