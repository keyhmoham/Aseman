"""Agents improving their own work with GEPA (gepa-ai/gepa).

Each agent has a playbook per space: lessons from its own turns there, at the
end of its system prompt. After every turn the runtime keeps what the turn did
and how it went, as decision points (record.py): the calls that failed or were
repeated, an answer that fell short, steps that worked. Every few turns, or
soon after a turn that went badly, a learning cycle runs in the background:
GEPA replays those moments with candidate playbooks, the agent's own model
taking the next step and a judge scoring it (replay.py), and reflects on the
feedback to write better ones. A new playbook is adopted only when it scores
better than the current one on the same moments; every version stays in the
playbook's history (store.py).

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


@dataclass(frozen=True)
class Settings:
    #: A cycle once this many turns were recorded since the last one...
    every: int = 10
    #: ...or sooner after a turn with problems, but never twice within this (seconds).
    cooldown: float = 3 * 3600.0
    #: GEPA's budget for one cycle: replayed steps, all candidates together.
    budget: int = 60
    #: Decision points a cycle needs, at least, and uses, at most.
    min_points: int = 4
    max_points: int = 10
    #: How much better on the same moments a new playbook must score to be adopted.
    margin: float = 0.05

    @classmethod
    def from_env(cls) -> Settings:
        def num(name: str, default: float) -> float:
            try:
                return float(os.environ.get(name, "") or default)
            except ValueError:
                return default

        return cls(every=max(1, int(num("TRADERA_IMPROVE_EVERY", cls.every))),
                   cooldown=max(0.0, num("TRADERA_IMPROVE_COOLDOWN", cls.cooldown)),
                   budget=max(10, int(num("TRADERA_IMPROVE_BUDGET", cls.budget))))


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

    def prepare(self, ctx: Any, system: str) -> str:
        """The system prompt with the agent's playbook in this space."""
        if ctx.turn.no_memory:
            return system
        book = self._store(ctx).playbook()
        ctx.learning = TurnNotes(system=system, version=book.version)
        playbook = replay.render(book.text)
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
        due = (state.turns_since >= self.settings.every or troubled) and \
            time.time() - state.last_cycle >= self.settings.cooldown and store.dir not in self._running
        points = gather(store.turns(), self.settings.max_points) if due else []
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
        book = store.playbook()
        learn = replay.Learn(self.node_url, self.secret, space, agent_vm, model, transport=self.transport)
        try:
            best, score, seed = await asyncio.to_thread(
                replay.optimize, points, playbook=book.text, system=store.system(), tools=store.tools(),
                learn=learn, budget=self.settings.budget)
        except Exception:  # noqa: BLE001 - learning never fails the runtime
            log.exception("learning cycle failed (%s)", store.dir)
            return
        finally:
            learn.close()
            self._running.discard(store.dir)
        if best.strip() and best.strip() != book.text.strip() and score >= seed + self.settings.margin:
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
