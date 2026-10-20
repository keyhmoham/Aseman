"""Where an agent's harness lives, per space.

    <root>/<space>/<agent>/champion/       the harness the agent works with (a harness2 tree)
    <root>/<space>/<agent>/challenger/     an improved harness on probe
    <root>/<space>/<agent>/history/<n>/    every harness adopted before
    <root>/<space>/<agent>/library/        harness2's experience library: INDEX.md, harnesses/<cycle>/
    <root>/<space>/<agent>/turns/          the latest turns: request, answer, trajectory, how it went
    <root>/<space>/<agent>/state.json      turns since the last cycle, when it ran, the champion's record

A harness is per agent and space, like the agent's memory: what an agent
learns in one space never shapes its work in another.
"""

from __future__ import annotations

import json
import re
import shutil
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

_ID = re.compile(r"[^a-zA-Z0-9_.-]+")
#: Turn records kept per agent and space.
KEEP_TURNS = 24
#: Champion turn outcomes kept as the baseline a challenger is compared with.
KEEP_BASELINE = 20


def _id(value: str) -> str:
    return _ID.sub("-", value).strip("-.")[:80] or "x"


@dataclass
class Probe:
    cycle: str
    started: float
    turns: int = 0
    outcomes: list[float] = field(default_factory=list)
    # Probed turns whose delivery the decision model judged (not only "it answered").
    judged: int = 0
    notes: str = ""


@dataclass
class State:
    turns_since: int = 0
    last_cycle: float = 0.0
    cycles: int = 0
    adopted: int = 0
    baseline: list[float] = field(default_factory=list)
    probe: Probe | None = None

    @classmethod
    def load(cls, path: Path) -> State:
        try:
            raw = json.loads(path.read_text())
        except (OSError, ValueError):
            return cls()
        probe = raw.pop("probe", None)
        state = cls(**{k: v for k, v in raw.items() if k in cls.__dataclass_fields__})
        state.probe = Probe(**probe) if isinstance(probe, dict) else None
        return state

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self), indent=2))
        tmp.replace(path)


class AgentHarness:
    """One agent's harness in one space, on disk."""

    def __init__(self, root: Path, space: str, agent: str) -> None:
        self.dir = Path(root) / _id(space) / _id(agent)

    @property
    def champion(self) -> Path:
        return self.dir / "champion"

    @property
    def challenger(self) -> Path:
        return self.dir / "challenger"

    @property
    def library(self) -> Path:
        return self.dir / "library"

    @property
    def state_path(self) -> Path:
        return self.dir / "state.json"

    def state(self) -> State:
        return State.load(self.state_path)

    def save(self, state: State) -> None:
        state.save(self.state_path)

    def record_turn(self, record: dict[str, Any]) -> Path:
        turns = self.dir / "turns"
        turns.mkdir(parents=True, exist_ok=True)
        path = turns / f"{time.time():.3f}.json"
        path.write_text(json.dumps(record, indent=2, ensure_ascii=False, default=str))
        for old in sorted(turns.glob("*.json"))[:-KEEP_TURNS]:
            old.unlink(missing_ok=True)
        return path

    def turns(self, n: int = 6) -> list[dict[str, Any]]:
        out = []
        for path in sorted((self.dir / "turns").glob("*.json"))[-n:]:
            try:
                out.append(json.loads(path.read_text()))
            except (OSError, ValueError):
                continue
        return out

    def adopt(self) -> None:
        """The challenger becomes the champion (the champion goes to history)."""
        if self.champion.is_dir():
            history = self.dir / "history"
            history.mkdir(parents=True, exist_ok=True)
            n = len([p for p in history.iterdir() if p.is_dir()]) + 1
            shutil.move(str(self.champion), str(history / f"{n:04d}"))
        shutil.move(str(self.challenger), str(self.champion))

    def discard(self) -> None:
        shutil.rmtree(self.challenger, ignore_errors=True)
