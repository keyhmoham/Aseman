"""Agents that improve their own harness as they work, with harness2.

An agent's harness is everything around its model that it can change without
changing the model: harness2's eight components (google-research/harness2),
in its OpenCode layout — always-on text (``systemprompt.md``, ``guardrails.md``,
``LongTermMEMORY.md``, ``tool_descriptions/tool_guidance.md``), skills,
subagents, scripts and plugins. It starts empty: the agent's definition and
the platform's prompts are not part of it and never change. Each agent has one
per space (store.py), loaded into its OpenCode project on every turn
(opencode/workspace.py): the always-on text after its system prompt, skills as
OpenCode skills, subagents as OpenCode subagents, scripts in the space's
sandbox, plugins (only when the node allows them) in its OpenCode.

harness2's two levels of recursion, online — the agent improves over the
course of its real work, never re-running a request (that would repeat its
effects: messages, files, purchases):

* task level: when a turn went poorly (the decision model doubts it delivered,
  tools failed, the steps ran out) or every few turns, a cycle runs in the
  background. **Propose**: harness2's editor writes two candidates from the
  agent's recent trajectories — INV (how the agent works) and DOM (what a
  practitioner of its work knows). **Compose**: harness2's composer merges
  what the evidence supports into one harness (or keeps the current one).
  **Probe**: the composed harness works the agent's next turns instead of the
  current one, and how those turns go — whether they delivered, as the
  decision model judges, how many steps they took, how many tools failed — is
  compared with how the current harness's turns went; it is adopted only when
  it does at least as well on that evidence, and dropped otherwise. Without a
  decision model nothing could be shown to do better, so no cycle runs.
* harnessing level: harness2's experience reflector reads the whole cycle and
  writes the lesson the evidence supports into the agent's experience library
  (harness2's Library: the adopted harness and its EXPERIENCE.md), which every
  later cycle reads before it proposes.

The editing stages are OpenCode sessions (editor.py) on the agent's own model,
billed to the project as the agent's learning. Turned off with
``TRADERA_HARNESS=0``, and never used or learned from for a request made
without memory.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..context import TurnContext
from ..opencode.workspace import HarnessFiles
from .store import AgentHarness, Probe, State

log = logging.getLogger("tradera.agents.harness")

try:  # harness2 is part of the runtime image; without it agents keep a fixed harness.
    from harness2.core import library as h2library
    from harness2.core import prompts as h2prompts
    from harness2.core import tree as h2tree
    from harness2.core.spec import BenchPrompts
    from harness2.substrate.opencode import OPENCODE_SURFACE, render_events

    AVAILABLE = True
except ImportError:  # pragma: no cover - depends on the image
    AVAILABLE = False

_NOTES = re.compile(r"<notes>(.*?)</notes>", re.S)
_EDITS = re.compile(r"<edits>(.*?)</edits>", re.S)
_EXPERIENCE = re.compile(r"<experience>(.*?)</experience>", re.S)
# Words harness2 keeps out of the work description (it describes the work, never its measurement).
_MEASURE = {"benchmark": "reference task", "evaluation": "assessment", "grader": "reviewer", "rubric": "checklist",
            "score": "rating"}
_MEASURE_RE = re.compile("|".join(_MEASURE), re.I)


@dataclass
class Settings:
    enabled: bool = True
    #: A cycle at the latest after this many turns of the current harness.
    every: int = 12
    #: A turn going below this quality starts a cycle early.
    low: float = 0.5
    #: At least this long between two cycles of one agent in one space (seconds).
    cooldown: float = 6 * 3600.0
    #: Turns a composed harness works before it is adopted or dropped.
    probe_turns: int = 3
    #: A probed harness is adopted when its turns go at least this close to the current one's.
    tolerance: float = 0.03
    #: Agents' harness plugins run in the runtime's OpenCode: only when the node allows it.
    plugins: bool = False

    @classmethod
    def from_env(cls) -> Settings:
        def num(name: str, default: float) -> float:
            try:
                return float(os.environ.get(name, "") or default)
            except ValueError:
                return default

        return cls(enabled=os.environ.get("TRADERA_HARNESS", "1") != "0",
                   every=max(1, int(num("TRADERA_HARNESS_EVERY", 12))),
                   cooldown=max(0.0, num("TRADERA_HARNESS_COOLDOWN", 6 * 3600.0)),
                   probe_turns=max(1, int(num("TRADERA_HARNESS_PROBE_TURNS", 3))),
                   plugins=os.environ.get("TRADERA_HARNESS_PLUGINS", "0") == "1")


@dataclass
class View:
    """The harness a turn works with."""

    arm: str  # "champion" or "challenger"
    tree: dict[str, str]
    files: HarnessFiles = field(default_factory=HarnessFiles)
    always_on: str = ""
    plugins_enabled: bool = False
    agent: AgentHarness | None = None


def _frontmatter(body: str) -> tuple[dict[str, str], str]:
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", body, re.S)
    if not m:
        return {}, body
    meta = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            meta[k.strip()] = v.strip().strip('"')
    return meta, body[m.end():]


def files_of(tree: dict[str, str], plugins: bool) -> HarnessFiles:
    """The OpenCode-native parts of a harness tree."""
    out = HarnessFiles()
    for rel, body in tree.items():
        parts = rel.split("/")
        if len(parts) == 3 and parts[0] == "skills" and parts[2] == "SKILL.md":
            out.skills[parts[1]] = body
        elif len(parts) >= 4 and parts[0] == "skills" and parts[2] == "scripts":
            out.skill_files[rel] = body
        elif len(parts) == 3 and parts[0] == "sub_agents" and parts[2] == "AGENT.md":
            meta, prompt = _frontmatter(body)
            out.subagents[parts[1]] = {"description": meta.get("description", parts[1]), "prompt": prompt.strip()}
        elif plugins and len(parts) == 2 and parts[0] == "plugin" and parts[1].endswith(".ts"):
            out.plugins[parts[1][:-3]] = body
    return out


def score(run: Any, outcome: Any, complete: float | None) -> float:
    """How a turn went, without knowing the right answer: whether it delivered
    (the decision model's judgement, else whether it answered at all), how many
    of its steps it needed, and how many of its tool calls failed."""
    if getattr(outcome, "status", "") == "failed":
        return 0.0
    if getattr(outcome, "status", "") == "awaiting":
        return 0.6
    delivered = complete if complete is not None else (1.0 if (outcome.reply or "").strip() else 0.0)
    budget = max(1, run.guard.budget)
    efficiency = 1.0 - min(1.0, run.guard.calls / budget)
    tools = [t for t in run.trajectory if t.get("type") == "tool"]
    failures = sum(1 for t in tools if (t.get("state") or {}).get("status") == "error")
    errors = failures / len(tools) if tools else 0.0
    return max(0.0, min(1.0, 0.75 * delivered + 0.25 * efficiency - 0.2 * errors))


def _safe(text: str) -> str:
    return _MEASURE_RE.sub(lambda m: _MEASURE[m.group(0).lower()], text)


def bench_prompts(ctx: TurnContext) -> Any:
    """harness2's description of the work: this agent's, on Tradera."""
    agent = ctx.agent
    work = (f"The agent `{agent.name}` works on Tradera, a shared project space where people and AI agents work "
            "together: it takes requests from people and from the space's lead agent in chat rooms, works on the "
            "project's shared Linux computer (its shell and files), uses the project's apps and tools, and can hand "
            "parts of the work to the space's other agents. Each request it gets is one task; its answer in the room "
            "is the deliverable.")
    if agent.description:
        work += f"\n\nWhat it does: {agent.description}"
    if agent.instructions.strip():
        work += f"\n\nIts standing instructions (fixed, not part of the harness):\n{agent.instructions.strip()[:3000]}"
    return BenchPrompts(
        work=_safe(work), domain_word="line of work", deliverable_word="answer",
        inv_levers=_safe("The agent's tools: `execute` (the shared computer's shell), `read_file`, `write_file`, "
                         "`edit_file`, `ls`, `glob`, `grep` (its files, under /workspace), `send_message`, `task` / "
                         "`start_task` / `wait_tasks` (delegating to other agents), `write_todos` (its plan), memory "
                         "(`remember`, `recall`) and the project's app tools. Harness scripts run on the shared "
                         "computer with `execute`; harness subagents run with the `subagent` tool and harness skills "
                         "load with the `skill` tool."),
        domain_guidance=_safe("Requests vary from turn to turn. Encode what recurs in this agent's work: its "
                              "procedures, its failure patterns, the facts of this project that every request needs. "
                              "Never encode one request's content."))


def render(trajectory: list[dict[str, Any]]) -> str:
    """A turn's trajectory in harness2's grammar."""
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for item in trajectory:
            f.write(json.dumps({"part": item}, default=str) + "\n")
        path = Path(f.name)
    try:
        return render_events(path, obs_trunc=1500, max_chars=40_000)
    finally:
        path.unlink(missing_ok=True)


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


class Harness:
    """The agents' self-improvement (one per runtime)."""

    def __init__(self, root: str | Path, editor: Any, settings: Settings | None = None) -> None:
        self.root = Path(root)
        self.editor = editor
        self.settings = settings or Settings.from_env()
        self._tasks: set[asyncio.Task[Any]] = set()
        self._busy: set[str] = set()
        self._uploaded: dict[str, str] = {}

    @property
    def active(self) -> bool:
        return AVAILABLE and self.settings.enabled and self.editor is not None

    def agent(self, ctx: TurnContext) -> AgentHarness:
        return AgentHarness(self.root, ctx.space, ctx.agent.vm_id or ctx.agent.name)

    # --- on every turn ------------------------------------------------------------

    async def view(self, ctx: TurnContext) -> View | None:
        """The harness the turn works with: the probed one while a probe runs."""
        if not self.active or ctx.turn.no_memory:
            return None
        ah = self.agent(ctx)
        state = ah.state()
        arm = "challenger" if state.probe is not None and ah.challenger.is_dir() else "champion"
        tree = h2tree.read_tree(OPENCODE_SURFACE, ah.challenger if arm == "challenger" else ah.champion)
        view = View(arm=arm, tree=tree, files=files_of(tree, self.settings.plugins),
                    plugins_enabled=self.settings.plugins, agent=ah)
        texts = [tree.get(name, "").strip() for name in OPENCODE_SURFACE.always_on]
        scripts = {rel: body for rel, body in tree.items() if rel.startswith("scripts/") or "/scripts/" in rel}
        lines = [t for t in texts if t]
        if scripts and not ctx.turn.no_sandbox:
            base = await self._upload_scripts(ctx, scripts)
            if base:
                lines.append(f"Your helper scripts are on the shared computer under {base}/ (run them with `execute`, "
                             f"e.g. `python3 {base}/scripts/<name>.py`).")
        if view.files.subagents:
            lines.append("Your subagents run with the `subagent` tool: " + ", ".join(sorted(view.files.subagents)) + ".")
        if lines:
            view.always_on = ("## Your harness\nWhat you learned from your earlier work in this space about doing it "
                              "well. It changes as you work.\n\n" + "\n\n".join(lines))
        return view

    async def _upload_scripts(self, ctx: TurnContext, scripts: dict[str, str]) -> str:
        from ..agent import slug
        from ..sandbox import WORKSPACE, FilesUnreadable, TraderaSandbox

        base = f"{WORKSPACE}/.tradera/agents/{slug(ctx.agent.name)}/harness"
        digest = json.dumps(sorted(scripts.items()))
        key = f"{ctx.space}:{ctx.agent.vm_id}"
        if self._uploaded.get(key) == digest:
            return base
        files = [(f"{base}/{rel}", body.encode()) for rel, body in scripts.items()]
        backend = TraderaSandbox(ctx)
        try:
            if not await asyncio.to_thread(backend.store_files, files):
                await backend.aupload_files(files)
        except FilesUnreadable:
            return ""
        except Exception as exc:  # noqa: BLE001 - the turn goes on without them
            log.warning("harness scripts not uploaded: %s", exc)
            return ""
        self._uploaded[key] = digest
        return base

    async def observe(self, ctx: TurnContext, run: Any, outcome: Any, view: View | None) -> None:
        """Record how the turn went; start or settle an improvement cycle."""
        if view is None or view.agent is None:
            return
        complete = None
        decision = ctx.decision
        if decision is not None and decision.enabled and outcome.status == "done" and outcome.reply:
            from ..decision.completion import complete as completion_probability

            complete = await completion_probability(decision, ctx.turn.message, outcome.reply, run.delivered)
        quality = score(run, outcome, complete)
        ah = view.agent
        ah.record_turn({"request": ctx.turn.message[:4000], "answer": (outcome.reply or "")[:4000],
                        "status": outcome.status, "arm": view.arm, "quality": round(quality, 3),
                        "steps": run.guard.calls, "budget": run.guard.budget, "trajectory": render(run.trajectory)})
        state = ah.state()
        bench = bench_prompts(ctx)
        if view.arm == "challenger" and state.probe is not None:
            state.probe.turns += 1
            state.probe.outcomes.append(quality)
            state.probe.judged += int(complete is not None or outcome.status == "failed")
            if state.probe.turns >= self.settings.probe_turns:
                self._spawn(ah, self._settle(ah, state, bench, ctx.space, ctx.agent.vm_id))
                return
            ah.save(state)
            return
        state.baseline = (state.baseline + [quality])[-20:]
        state.turns_since += 1
        if decision is None or not decision.enabled:
            # Without the decision model a new harness could never be shown to
            # do better (see _settle): no cycle is spent on one.
            ah.save(state)
            return
        due = quality < self.settings.low or state.turns_since >= self.settings.every
        cooled = time.time() - state.last_cycle >= self.settings.cooldown
        if due and cooled and state.probe is None and str(ah.dir) not in self._busy:
            state.turns_since, state.last_cycle = 0, time.time()
            ah.save(state)
            self._spawn(ah, self._cycle(ah, bench, ctx.space, ctx.agent.vm_id))
            return
        ah.save(state)

    def _spawn(self, ah: AgentHarness, work: Any) -> None:
        key = str(ah.dir)
        self._busy.add(key)

        async def guarded() -> None:
            try:
                await work
            except Exception:  # noqa: BLE001 - learning never breaks the agent
                log.exception("harness cycle failed for %s", ah.dir)
            finally:
                self._busy.discard(key)

        task = asyncio.create_task(guarded())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def drain(self, timeout: float = 30.0) -> None:
        if self._tasks:
            await asyncio.wait(list(self._tasks), timeout=timeout)

    # --- a cycle -------------------------------------------------------------------

    def _evidence(self, work: Path, ah: AgentHarness, base: dict[str, str]) -> str:
        """Lay out a stage's evidence under work/context; the layout for its mission."""
        context = work / "context"
        context.mkdir(parents=True, exist_ok=True)
        turns = ah.turns(6)
        (context / "task.md").write_text(
            "# The agent's recent work\n\nEach rollout under context/rollouts/ is one real request the agent "
            "handled, with its trajectory. Requests differ: improve how the agent handles requests like these, "
            "not one request.\n", encoding="utf-8")
        rollouts = context / "rollouts"
        rollouts.mkdir(exist_ok=True)
        names = []
        for i, t in enumerate(turns, 1):
            name = f"turn-{i}"
            names.append(name)
            outcome = {"done": "finished", "failed": "failed", "awaiting": "paused for people"}.get(t.get("status"), "")
            (rollouts / f"{name}.md").write_text(
                f"# {name} ({'current harness' if t.get('arm') == 'champion' else 'probed harness'}; {outcome}; "
                f"{t.get('steps')} of {t.get('budget')} steps)\n\n## Request\n{t.get('request', '')}\n\n"
                f"## Answer\n{t.get('answer', '')}\n\n## Trajectory\n{t.get('trajectory', '')}\n", encoding="utf-8")
        h2tree.write_tree(OPENCODE_SURFACE, base, context / "harness")
        library = h2library.Library(ah.dir, "library", OPENCODE_SURFACE)
        layout = ["context/task.md                  what these rollouts are",
                  f"context/rollouts/               FULL trajectories: {', '.join(n + '.md' for n in names)}",
                  f"context/harness/                the harness you are editing ({len(base)} files)"]
        if library.context_dir() is not None:
            shutil.copytree(library.dir, context / "library", dirs_exist_ok=True)
            layout.append("context/library/                earlier improvements of this agent -- browse INDEX.md first")
        return "\n".join(layout)

    async def _stage(self, work: Path, job: str, layout: str, space: str, agent_vm: str, label: str) -> str:
        mission = "\n\n".join([job.strip(), "# YOUR EVIDENCE\n\nIt is on disk, in `context/`. Read it -- do not "
                               "answer from this message alone.\n\n" + layout])
        return await self.editor.session(work, mission, space=space, agent_vm=agent_vm, label=label)

    def _read(self, work: Path, base: dict[str, str], label: str) -> dict[str, str] | None:
        tree = h2tree.read_tree(OPENCODE_SURFACE, work / "context" / "harness")
        if not self.settings.plugins:
            tree = {rel: body for rel, body in tree.items() if not rel.startswith("plugin/")}
        h2tree.autotrigger(OPENCODE_SURFACE, tree)
        try:
            h2tree.validate(OPENCODE_SURFACE, tree)
        except ValueError as exc:
            log.info("harness %s rejected: %s", label, str(exc)[:500])
            return None
        return tree

    async def _cycle(self, ah: AgentHarness, bench: Any, space: str, agent_vm: str) -> None:
        """Propose (INV and DOM) and compose: a harness to probe."""
        cycle = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        base = h2tree.read_tree(OPENCODE_SURFACE, ah.champion)
        work = self.root / "work" / cycle
        try:
            async def propose(dim: str) -> tuple[dict[str, str] | None, str]:
                stage = work / dim.lower()
                layout = self._evidence(stage, ah, base)
                text = await self._stage(stage, h2prompts.propose(bench, dim, OPENCODE_SURFACE), layout, space,
                                         agent_vm, f"harness {cycle} {dim}")
                notes = _NOTES.search(text or "")
                return self._read(stage, base, dim), notes.group(1).strip() if notes else ""

            (inv, inv_notes), (dom, dom_notes) = await asyncio.gather(propose("INV"), propose("DOM"))
            candidates = {label: tree for label, tree in (("inv", inv), ("dom", dom)) if tree is not None}
            candidates = {k: v for k, v in candidates.items() if v != base}
            if not candidates:
                log.info("harness %s: no change proposed for %s", cycle, ah.dir)
                return
            stage = work / "compose"
            layout = self._evidence(stage, ah, base)
            pool = stage / "context" / "pool"
            for label, tree in candidates.items():
                h2tree.write_tree(OPENCODE_SURFACE, tree, pool / label / "harness", stubs=False)
                (pool / label / "notes.md").write_text({"inv": inv_notes, "dom": dom_notes}[label] or "(no notes)")
            layout += (f"\ncontext/pool/                   {len(candidates)} candidates ({', '.join(candidates)}), "
                       "each a harness and its proposer's notes")
            job = h2prompts.aggregate(bench, OPENCODE_SURFACE) + (
                "\n\n# HERE, CANDIDATES ARE PROBED AFTER YOU\n\nThe candidates have not run yet: the rollouts are "
                "the agent's recent real requests under the current harness. Compose from what those rollouts "
                "support; the harness you compose then works the agent's next real requests and is kept only if they "
                "go at least as well.")
            await self._stage(stage, job, layout, space, agent_vm, f"harness {cycle} compose")
            final = self._read(stage, base, "compose") or next(iter(candidates.values()))
            if final == base:
                log.info("harness %s: kept the current harness for %s", cycle, ah.dir)
                return
            ah.discard()
            h2tree.write_tree(OPENCODE_SURFACE, final, ah.challenger, stubs=False)
            state = ah.state()
            state.cycles += 1
            state.probe = Probe(cycle=cycle, started=time.time(),
                                notes="\n\n".join(n for n in (inv_notes, dom_notes) if n)[:4000])
            ah.save(state)
            log.info("harness %s: probing a new harness for %s (%s)", cycle, ah.dir,
                     h2tree.diff_summary(OPENCODE_SURFACE, base, final))
        finally:
            shutil.rmtree(work, ignore_errors=True)

    async def _settle(self, ah: AgentHarness, state: State, bench: Any, space: str, agent_vm: str) -> None:
        """Adopt or drop the probed harness; reflect on the cycle."""
        probe = state.probe
        assert probe is not None
        base = h2tree.read_tree(OPENCODE_SURFACE, ah.champion)
        challenger = h2tree.read_tree(OPENCODE_SURFACE, ah.challenger)
        baseline = _mean(state.baseline[-10:]) if state.baseline else 0.6
        probed = _mean(probe.outcomes)
        # Adopted only on evidence: enough probed turns judged (did they deliver?),
        # going at least as well as the current harness. A harness whose turns
        # only show that the agent answered is not kept.
        judged = probe.judged * 2 >= len(probe.outcomes)
        adopted = judged and probed >= baseline - self.settings.tolerance
        if adopted:
            ah.adopt()
            state.adopted += 1
        else:
            ah.discard()
        state.probe = None
        ah.save(state)
        log.info("harness %s for %s: %s (probe %.2f vs current %.2f)", probe.cycle, ah.dir,
                 "adopted" if adopted else "dropped", probed, baseline)
        # The harnessing level: what this cycle teaches, for the next ones.
        work = self.root / "work" / (probe.cycle + "-reflect")
        try:
            layout = self._evidence(work, ah, challenger)
            h2tree.write_tree(OPENCODE_SURFACE, base, work / "context" / "base_harness")
            layout += "\ncontext/base_harness/           the harness before this cycle"
            verdict = ("at least as well, so it was ADOPTED" if adopted else
                       "worse, so it was DROPPED" if judged else
                       "without an independent judgement of whether they delivered, so it was DROPPED (not proven)")
            what = (f"The edited harness (context/harness/) worked the agent's next {len(probe.outcomes)} real "
                    f"requests (the rollouts marked 'probed harness'). Compared with how the requests before went "
                    f"under the base harness, they went {verdict}. The proposers' notes:\n\n{probe.notes or '(none)'}")
            text = await self._stage(work, h2prompts.experience(bench) + "\n\n# WHAT HAPPENED\n\n" + what, layout,
                                     space, agent_vm, f"harness {probe.cycle} reflect")
            experience = _parse_experience(text)
            if experience:
                edits = _EDITS.search(text or "")
                if edits:
                    experience["edits"] = edits.group(1).strip()
                library = h2library.Library(ah.dir, "library", OPENCODE_SURFACE)
                library.add(probe.cycle, challenger, why=what, label="adopted" if adopted else "dropped",
                            experience=experience)
        finally:
            shutil.rmtree(work, ignore_errors=True)


def _parse_experience(text: str) -> dict[str, str]:
    m = _EXPERIENCE.search(text or "")
    if not m:
        return {}
    out: dict[str, str] = {}
    for line in m.group(1).strip().splitlines():
        key, _, value = line.partition(":")
        key = key.strip().lower()
        if key in ("cue", "lesson", "evidence", "confidence") and value.strip():
            out[key] = value.strip()
    return out if all(out.get(k) for k in ("cue", "lesson", "evidence")) else {}


def from_env(data_dir: str | Path, engine: Any, secret: str) -> Harness | None:
    """The runtime's harness, or None when it cannot learn (turned off, harness2
    missing, or no way to reach the node's learn endpoint)."""
    settings = Settings.from_env()
    node_url = os.environ.get("TRADERA_NODE_URL", "").strip()
    if not settings.enabled:
        return None
    if not AVAILABLE:
        log.warning("harness2 is not installed: agents keep a fixed harness")
        return None
    if not node_url or not secret:
        log.warning("no node URL or runtime secret: agents keep a fixed harness")
        return None
    import httpx

    from .editor import Editor

    root = Path(data_dir) / "harness"
    editor = Editor(engine, root, node_url=node_url, secret=secret,
                    client=httpx.AsyncClient(timeout=httpx.Timeout(connect=10.0, read=600.0, write=60.0, pool=30.0)))
    return Harness(root, editor, settings)
