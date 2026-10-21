"""Agents improving their own work with GEPA (gepa-ai/gepa).

Each agent has a playbook per space: lessons from its own turns there, at the
end of its system prompt. After every turn the runtime keeps what the turn did
and how it went, as decision points (record.py): the calls that failed or were
repeated, an answer that fell short, steps that worked. Every few turns, or
soon after a turn that went badly, a learning cycle runs in the background:
GEPA replays those moments with candidate playbooks, the agent's own model
taking the next step and a judge scoring it (replay.py), and reflects on the
feedback to write better ones. A turn where the agent looped (it was told it
repeated calls or read instructions it already had) is taken up much sooner. A new playbook is adopted only when it scores
better than the current one on the same moments; every version stays in the
playbook's history (store.py).

A playbook expires (``TRADERA_IMPROVE_MAX_AGE_DAYS``, 30 days by default):
an old one stops shaping the agent's work until a new cycle adopts a better
one. Nothing learned before ``LEARNED_SINCE`` is used, playbooks or turns:
they were learned while the runtime itself refused calls and hid tools, and
teach workarounds for that. ``Improver.reset`` forgets an agent's learning.

Nothing of a turn runs again and nothing slows one down: the cycle runs after
it, off the turn's path, on the node's learn endpoints (billed to the project
as its agents' learning). A turn that asked for no memory neither uses the
playbook nor teaches it.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from langchain_core.utils.function_calling import convert_to_openai_tool

from ..decision import completion
from ..decision.middleware import delivered, last_request
from . import record, replay
from .store import AgentStore

log = logging.getLogger("tradera.agents.improve")

#: What was learned before this (2026-10-21T00:00:00Z) is not used.
LEARNED_SINCE = 1792540800.0


@dataclass(frozen=True)
class Settings:
    #: A cycle once this many turns were recorded since the last one...
    every: int = 10
    #: ...or sooner after a turn with problems, but never twice within this (seconds)...
    cooldown: float = 3 * 3600.0
    #: ...or this, after a turn where the agent looped.
    loop_cooldown: float = 15 * 60.0
    #: GEPA's budget for one cycle: replayed steps, all candidates together.
    budget: int = 60
    #: Decision points a cycle needs, at least, and uses, at most.
    min_points: int = 4
    max_points: int = 10
    #: How much better on the same moments a new playbook must score to be adopted.
    margin: float = 0.05
    #: A playbook is used this long after it was adopted (seconds; 0: always).
    max_age: float = 30 * 86400.0

    @classmethod
    def from_env(cls) -> Settings:
        def num(name: str, default: float) -> float:
            try:
                return float(os.environ.get(name, "") or default)
            except ValueError:
                return default

        return cls(every=max(1, int(num("TRADERA_IMPROVE_EVERY", cls.every))),
                   cooldown=max(0.0, num("TRADERA_IMPROVE_COOLDOWN", cls.cooldown)),
                   loop_cooldown=max(0.0, num("TRADERA_IMPROVE_LOOP_COOLDOWN", cls.loop_cooldown)),
                   budget=max(10, int(num("TRADERA_IMPROVE_BUDGET", cls.budget))),
                   max_age=max(0.0, num("TRADERA_IMPROVE_MAX_AGE_DAYS", cls.max_age / 86400.0) * 86400.0))


@dataclass
class TurnNotes:
    """What a turn's learning keeps from when it was built."""

    system: str  # the system prompt without the playbook
    version: int  # the playbook version the turn ran with


class Improver:
    """The agents' self-improvement: one per runtime process."""

    def __init__(self, root: str | Path, node_url: str, secret: str, settings: Settings | None = None, *,
                 transport: httpx.BaseTransport | None = None) -> None:
        self.root = Path(root)
        self.node_url = node_url
        self.secret = secret
        self.settings = settings or Settings()
        self.transport = transport
        self._tasks: set[asyncio.Task[None]] = set()
        self._running: set[Path] = set()

    def _store(self, ctx: Any) -> AgentStore:
        return AgentStore(self.root, ctx.space, ctx.agent.vm_id)

    def _playbook(self, store: AgentStore) -> str:
        """The playbook's text while it may be used, else ''."""
        book = store.playbook()
        return book.text if book.current(LEARNED_SINCE, self.settings.max_age) else ""

    def reset(self, space: str = "", agent_vm: str = "") -> int:
        """Forget what agents learned: one agent in one space, every agent of a
        space, or (both empty) every agent. Returns how many were reset."""
        if space and agent_vm:
            stores = [AgentStore(self.root, space, agent_vm)]
        else:
            spaces = [AgentStore(self.root, space, "x").dir.parent] if space else \
                [p for p in self.root.glob("*") if p.is_dir()]
            stores = [AgentStore(self.root, s.name, a.name) for s in spaces for a in s.glob("*") if a.is_dir()]
        for store in stores:
            store.reset()
        return len(stores)

    def prepare(self, ctx: Any, system: str) -> str:
        """The system prompt with the agent's playbook in this space."""
        if ctx.turn.no_memory:
            return system
        store = self._store(ctx)
        ctx.learning = TurnNotes(system=system, version=store.playbook().version)
        playbook = replay.render(self._playbook(store))
        return f"{system}\n\n{playbook}" if playbook else system

    async def observe(self, ctx: Any, outcome: Any, messages: list[Any], guard: Any, graph: Any) -> None:
        """Keep the finished turn; start a learning cycle when one is due."""
        notes: TurnNotes | None = ctx.learning
        if notes is None or not messages or outcome.status == "cancelled":
            return
        request = last_request(messages) or ctx.turn.message
        complete = None
        if ctx.decision is not None and outcome.status == "done":
            complete = await completion.complete(ctx.decision, request, outcome.reply, delivered(messages))
        quality = record.quality(outcome, complete, messages, guard.calls, guard.budget)
        schemas = tool_schemas(graph)
        turn = record.turn(request, outcome, messages, quality=quality, complete=complete, steps=guard.calls,
                           budget=guard.budget, version=notes.version, tools=list(schemas))
        store = self._store(ctx)
        try:
            await asyncio.to_thread(self._keep, store, turn, notes.system, schemas)
        except OSError as exc:
            log.warning("could not keep the turn to learn from: %s", exc)
            return
        state = store.state()
        state.turns_since += 1
        troubled = quality < 0.5 or any(p["kind"] != "good" for p in turn["points"])
        looped = getattr(guard, "loops", 0) > 0 or any(p["kind"] == "repeat" for p in turn["points"])
        cooldown = min(self.settings.cooldown, self.settings.loop_cooldown) if looped else self.settings.cooldown
        due = (state.turns_since >= self.settings.every or troubled or looped) and \
            time.time() - state.last_cycle >= cooldown and store.dir not in self._running
        points = gather(store.turns(since=LEARNED_SINCE), self.settings.max_points) if due else []
        if len(points) >= self.settings.min_points:
            state.turns_since, state.last_cycle, state.cycles = 0, time.time(), state.cycles + 1
            self._start(store, points, ctx.space, ctx.agent.vm_id, ctx.agent.model)
        store.save(state)

    @staticmethod
    def _keep(store: AgentStore, turn: dict[str, Any], system: str, schemas: dict[str, dict[str, Any]]) -> None:
        store.record(turn, system)
        store.put_tools(schemas)

    def _start(self, store: AgentStore, points: list[dict[str, Any]], space: str, agent_vm: str, model: str) -> None:
        self._running.add(store.dir)
        task = asyncio.create_task(self._cycle(store, points, space, agent_vm, model))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _cycle(self, store: AgentStore, points: list[dict[str, Any]], space: str, agent_vm: str,
                     model: str) -> None:
        current = self._playbook(store)
        learn = replay.Learn(self.node_url, self.secret, space, agent_vm, model, transport=self.transport)
        try:
            best, score, seed = await asyncio.to_thread(
                replay.optimize, points, playbook=current, system=store.system(), tools=store.tools(),
                learn=learn, budget=self.settings.budget)
        except Exception:  # noqa: BLE001 - learning never fails the runtime
            log.exception("learning cycle failed (%s)", store.dir)
            return
        finally:
            learn.close()
            self._running.discard(store.dir)
        if best.strip() and best.strip() != current.strip() and score >= seed + self.settings.margin:
            adopted = store.adopt(best.strip(), score=score, baseline=seed, evidence=len(points))
            log.info("playbook v%d adopted (%s): %.2f over %.2f on %d moments", adopted.version, store.dir, score,
                     seed, len(points))
        else:
            log.info("playbook kept (%s): best %.2f, current %.2f", store.dir, score, seed)

    async def drain(self) -> None:
        """Wait for the learning cycles running (shutdown, tests)."""
        while self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)


def tool_schemas(graph: Any) -> dict[str, dict[str, Any]]:
    """The schemas of the tools the agent had in the turn (its graph's tool node)."""
    node = getattr(graph, "nodes", {}).get("tools")
    tools = getattr(getattr(node, "bound", None), "tools_by_name", None) or {}
    out = {}
    for name, tool in tools.items():
        try:
            out[name] = convert_to_openai_tool(tool)
        except Exception:  # noqa: BLE001 - a tool without a schema is not replayed
            continue
    return out


def gather(turns: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    """The decision points a cycle learns from: the latest problems first, then
    steps that worked, so a new playbook also keeps what already works."""
    problems: list[dict[str, Any]] = []
    good: list[dict[str, Any]] = []
    for turn in reversed(turns):
        for p in turn.get("points") or []:
            point = {**p, "request": turn.get("request", ""), "tools": turn.get("tools") or []}
            (good if p.get("kind") == "good" else problems).append(point)
    chosen = problems[:limit]
    return chosen + good[:limit - len(chosen)]


def from_env(data_dir: str | Path, secret: str) -> Improver | None:
    """The runtime's Improver, or None when learning is off (TRADERA_IMPROVE=0)
    or the runtime cannot reach the node's learn endpoints."""
    node_url = os.environ.get("TRADERA_NODE_URL", "").strip()
    if os.environ.get("TRADERA_IMPROVE", "1") == "0" or not node_url or not secret:
        return None
    return Improver(Path(data_dir) / "improve", node_url, secret, Settings.from_env())
