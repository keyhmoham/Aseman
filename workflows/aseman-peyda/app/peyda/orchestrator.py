"""The agentic loop: the agent in the middle of GLiNER2 → iran-mcp.

One chat turn:

    message ─► [plan]      with history: the agent turns "cheaper ones" into a
                           standalone query (or just answers, no search needed)
            ─► extract     GLiNER2 reads the query into a frame
            ─► search      iran-mcp servers, in parallel
            ─► review      the agent reads the frame and what came back, and
                           either accepts, writes a better query (back to
                           extract), narrows or redirects the services, or asks
                           the person for what is missing
            ─► answer      the agent writes the reply from the best round

The agent is a participant, not a function: it sees the conversation's history
(sent with every ask: an ask is otherwise an isolated conversation) and the
structured memory of earlier searches, so a follow-up continues the thread.
The loop's limits are the server's, not the agent's: a round cap, a query that
repeats ends the loop, and the best round (not merely the last) is answered.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Protocol

from .extractor import Extractor
from .frame import QueryFrame, normalize_text
from .gateway import Gateway, SearchResult, ServiceRun
from .hits import Hit

log = logging.getLogger("peyda.orchestrator")


class AgentPort(Protocol):
    async def ask(self, prompt: str, history: list[dict[str, str]]) -> str: ...


def reason_of(e: BaseException) -> str:
    """One line on why the analyst failed, for the banner and the log. Messages from
    the platform or the SDK carry no credentials; the length is capped anyway."""
    text = " ".join(str(e).split())[:240]
    log.warning("the analyst failed: %s", text)
    return text


class AgentError(Exception):
    pass


class Cancelled(Exception):
    pass


@dataclass
class LoopConfig:
    max_rounds: int = 3
    per_service: int = 6
    max_services: int = 6
    turn_timeout: float = 240.0

    @classmethod
    def from_env(cls) -> "LoopConfig":
        return cls(
            max_rounds=max(1, min(5, int(os.environ.get("PEYDA_MAX_ROUNDS", "3")))),
            per_service=int(os.environ.get("PEYDA_HITS_PER_SERVICE", "6")),
            max_services=int(os.environ.get("PEYDA_MAX_SERVICES", "6")),
            turn_timeout=float(os.environ.get("PEYDA_TURN_TIMEOUT", "240")),
        )


# --------------------------------------------------------------------------
# A run: what the page polls
# --------------------------------------------------------------------------

@dataclass
class Run:
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    chat_id: str = ""
    user: str = ""
    status: str = "running"          # running | done | error | cancelled
    events: list[dict[str, Any]] = field(default_factory=list)
    message: dict[str, Any] | None = None
    error: str = ""
    cancelled: bool = False
    created: float = field(default_factory=time.time)

    def emit(self, type_: str, **data: Any) -> None:
        self.events.append({"i": len(self.events), "t": round(time.time() - self.created, 2), "type": type_, **data})

    def check(self) -> None:
        if self.cancelled:
            raise Cancelled()

    def view(self, after: int = 0) -> dict[str, Any]:
        return {"id": self.id, "chat": self.chat_id, "status": self.status, "error": self.error,
                "events": self.events[after:], "next": len(self.events), "message": self.message}


@dataclass
class Round:
    n: int
    query: str
    result: SearchResult
    verdict: dict[str, Any] = field(default_factory=dict)


# --------------------------------------------------------------------------
# Prompts. The agent's standing instructions live on the agent (the workflow
# installs them); each ask names its TASK and carries its DATA as JSON.
# --------------------------------------------------------------------------

def _prompt(task: str, data: dict[str, Any], reply_shape: str) -> str:
    return (
        f"TASK: {task}\n"
        f"DATA:\n{json.dumps(data, ensure_ascii=False)}\n\n"
        f"Reply with only this JSON, no prose around it:\n{reply_shape}"
    )


PLAN_SHAPE = ('{"action": "search" | "reply", "query": "<a complete, standalone search query in the user\'s language: '
              'every constraint that still applies, nothing the user dropped>", "reply": "<only when action is reply>"}')
REVIEW_SHAPE = ('{"verdict": "satisfied" | "refine" | "ask_user" | "give_up", "reason": "<one sentence>", '
                '"query": "<only for refine: a better standalone query, different from every earlier one>", '
                '"domains": ["<optional: domains to search instead>"], "exclude_services": ["<optional service ids to drop>"], '
                '"question": "<only for ask_user: one short question>"}')
ANSWER_SHAPE = ('{"answer": "<markdown, in the user\'s language: what was found, the best options first, prices in Toman, '
                'what you assumed or could not check>", "picks": ["<hit ref like digikala:0>", "..."], '
                '"suggestions": ["<up to 3 short follow-ups the user may want>"]}')


def _refs(result: SearchResult, per_service: int = 4) -> dict[str, Any]:
    """The digest with a ref (`service:index`) on every hit the agent may pick."""
    d = result.digest(per_service)
    for s in d["services"]:
        for i, h in enumerate(s["hits"]):
            h["ref"] = f"{s['id']}:{i}"
    return d


def parse_json_reply(text: str) -> dict[str, Any]:
    s = str(text or "")
    fenced = re.search(r"```(?:json)?\s*([\s\S]*?)```", s, re.I)
    for c in ([fenced.group(1)] if fenced else []) + [s]:
        start = c.find("{")
        if start < 0:
            continue
        for end in range(len(c), start, -1):
            if c[end - 1] != "}":
                continue
            try:
                v = json.loads(c[start:end])
            except ValueError:
                continue
            if isinstance(v, dict):
                return v
    raise AgentError("the analyst's reply had no JSON object")


# --------------------------------------------------------------------------
# The orchestrator
# --------------------------------------------------------------------------

class Orchestrator:
    def __init__(self, extractor: Extractor, gateway: Gateway, config: LoopConfig | None = None) -> None:
        self.extractor = extractor
        self.gateway = gateway
        self.cfg = config or LoopConfig.from_env()

    # -- plain search (no agent) -----------------------------------------
    async def search(self, text: str, *, limit: int | None = None, domains: list[str] | None = None) -> SearchResult:
        frame = await asyncio.to_thread(self.extractor.extract, text)
        return await self.gateway.search(frame, limit=limit or self.cfg.per_service,
                                         max_services=self.cfg.max_services, domains=domains)

    # -- one agent exchange ----------------------------------------------
    async def _ask(self, agent: AgentPort, task: str, data: dict[str, Any], shape: str, history: list[dict[str, str]]) -> dict[str, Any]:
        prompt = _prompt(task, data, shape)
        last: Exception | None = None
        for attempt in range(2):
            try:
                reply = await agent.ask(prompt if attempt == 0 else prompt + "\n\nYour last reply was not valid JSON. Reply with the JSON object only.", history)
                return parse_json_reply(reply)
            except AgentError as e:
                last = e
            except Exception as e:  # noqa: BLE001 - the agent or the platform failed
                raise AgentError(f"{type(e).__name__}: {e}") from e
        raise AgentError(str(last))

    # -- a chat turn ------------------------------------------------------
    async def turn(self, run: Run, text: str, history: list[dict[str, str]], memory: list[dict[str, Any]], agent: AgentPort) -> dict[str, Any]:
        """Runs the loop and returns the assistant message:
        {text, cards, suggestions, rounds, degraded, state}."""
        cfg = self.cfg
        degraded = False
        why = ""  # the first reason the analyst failed: shown with the banner, so it can be fixed
        query = normalize_text(text)
        rounds: list[Round] = []
        seen: set[str] = {query.lower()}
        directive: dict[str, Any] = {}

        # 1. plan: only when there is a conversation to continue
        if history or memory:
            run.emit("stage", name="plan", detail="reading your message in the context of the chat")
            try:
                plan = await self._ask(agent, "plan", {"message": text, "earlier_searches": memory[-4:]}, PLAN_SHAPE, history)
                run.check()
                if plan.get("action") == "reply" and str(plan.get("reply") or "").strip():
                    run.emit("note", text="answered from the conversation, no search needed")
                    return {"text": str(plan["reply"]).strip(), "cards": [], "suggestions": [], "rounds": [], "degraded": False}
                if str(plan.get("query") or "").strip():
                    query = normalize_text(str(plan["query"]))
                    seen.add(query.lower())
                    run.emit("note", text="query for this turn", query=query)
            except AgentError as e:
                degraded = True
                why = why or reason_of(e)
                run.emit("note", text="the analyst could not be reached for planning: searching your words as written", error=str(e))

        # 2..n. extract → search → review
        for n in range(1, cfg.max_rounds + 1):
            run.check()
            run.emit("stage", name="extract", round=n, query=query)
            frame = await asyncio.to_thread(self.extractor.extract, query)
            run.emit("frame", round=n, frame=frame.brief(), engine=frame.source, assumptions=frame.assumptions)

            run.emit("stage", name="search", round=n,
                     services=[s.id for s in self.gateway.catalog.route(frame, cfg.max_services, exclude=directive.get("exclude"), domains=directive.get("domains"))])

            def on_run(r: ServiceRun, _n: int = n) -> None:
                run.emit("service", round=_n, id=r.id, title=r.title, status=r.status, count=len(r.hits), ms=r.ms, reason=r.reason)

            result = await self.gateway.search(
                frame, limit=cfg.per_service, max_services=cfg.max_services,
                exclude=directive.get("exclude"), domains=directive.get("domains"), on_run=on_run,
            )
            rnd = Round(n=n, query=query, result=result)
            rounds.append(rnd)
            run.emit("results", round=n, total=result.total, score=result.score)
            run.check()
            if n == cfg.max_rounds:
                break

            run.emit("stage", name="review", round=n, detail="the analyst is reading the results")
            try:
                verdict = await self._ask(agent, "review", {
                    "message": text, "round": n, "max_rounds": cfg.max_rounds, "query": query,
                    "earlier_queries": [r.query for r in rounds[:-1]],
                    "scores": [{"round": r.n, "query": r.query, "score": r.result.score, "total": r.result.total} for r in rounds],
                    "results": _refs(result),
                    "domains_available": sorted({d for s in self.gateway.catalog.services.values() for d in s.domains}),
                }, REVIEW_SHAPE, history)
            except AgentError as e:
                degraded = True
                why = why or reason_of(e)
                run.emit("note", text="the analyst could not review this round: using these results", error=str(e))
                break
            run.check()
            rnd.verdict = verdict
            kind = str(verdict.get("verdict") or "satisfied")
            run.emit("review", round=n, verdict=kind, reason=str(verdict.get("reason") or ""), query=str(verdict.get("query") or ""))

            if kind == "ask_user" and str(verdict.get("question") or "").strip():
                return {"text": str(verdict["question"]).strip(), "cards": self._cards(rounds, []),
                        "suggestions": [], "rounds": self._rounds_view(rounds), "degraded": degraded, "degraded_reason": why,
                        "state": self._memory_entry(rounds, best=rnd)}
            if kind != "refine":
                break
            nxt = normalize_text(str(verdict.get("query") or ""))
            if not nxt or nxt.lower() in seen:
                run.emit("note", text="the analyst's new query repeats an earlier one: stopping here")
                break
            seen.add(nxt.lower())
            query = nxt
            directive = {
                "exclude": [s for s in (verdict.get("exclude_services") or []) if isinstance(s, str)] or None,
                "domains": [d for d in (verdict.get("domains") or []) if isinstance(d, str)] or None,
            }

        # last: answer from the best round (the last one wins ties)
        best = max(rounds, key=lambda r: (r.result.score, r.n))
        run.emit("stage", name="answer", round=best.n, detail="the analyst is writing the answer")
        picks: list[str] = []
        suggestions: list[str] = []
        try:
            ans = await self._ask(agent, "answer", {
                "message": text, "query": best.query, "rounds": len(rounds), "results": _refs(best.result, 5),
                "unreachable": [r.id for r in best.result.runs if r.status == "error"],
                "gaps": best.result.gaps,
            }, ANSWER_SHAPE, history)
            body = str(ans.get("answer") or "").strip()
            picks = [p for p in (ans.get("picks") or []) if isinstance(p, str)]
            suggestions = [s for s in (ans.get("suggestions") or []) if isinstance(s, str)][:3]
            if not body:
                raise AgentError("the analyst's answer was empty")
        except AgentError as e:
            degraded = True
            why = why or reason_of(e)
            run.emit("note", text="the analyst could not write the answer: showing the results as they came", error=str(e))
            body = self._fallback_answer(best)
        return {"text": body, "cards": self._cards(rounds, picks, best), "suggestions": suggestions,
                "rounds": self._rounds_view(rounds), "degraded": degraded, "degraded_reason": why, "state": self._memory_entry(rounds, best)}

    # -- shaping ----------------------------------------------------------
    @staticmethod
    def _cards(rounds: list[Round], picks: list[str], best: Round | None = None) -> list[dict[str, Any]]:
        best = best or rounds[-1]
        by_ref: dict[str, Hit] = {}
        titles: dict[str, str] = {}
        for r in best.result.runs:
            titles[r.id] = r.title
            for i, h in enumerate(r.hits[:5]):
                by_ref[f"{r.id}:{i}"] = h
        chosen = [p for p in dict.fromkeys(picks) if p in by_ref][:6]
        if not chosen:  # the agent named none: the first hit of each answering service
            chosen = [f"{r.id}:0" for r in best.result.runs if r.hits][:4]
        out = []
        for ref in chosen:
            d = by_ref[ref].to_dict()
            d["ref"], d["source"] = ref, titles.get(ref.split(":")[0], ref)
            out.append(d)
        return out

    @staticmethod
    def _rounds_view(rounds: list[Round]) -> list[dict[str, Any]]:
        return [{"n": r.n, "query": r.query, "score": r.result.score, "total": r.result.total,
                 "verdict": r.verdict.get("verdict", ""), "reason": r.verdict.get("reason", ""),
                 "slots": r.result.frame.slots, "domains": r.result.frame.domain_names[:3]} for r in rounds]

    @staticmethod
    def _memory_entry(rounds: list[Round], best: Round) -> dict[str, Any]:
        top = [h.title for r in best.result.runs for h in r.hits[:1]][:5]
        return {"query": best.query, "frame": best.result.frame.brief(), "top": top, "rounds": len(rounds)}

    @staticmethod
    def _fallback_answer(best: Round) -> str:
        lines = [f"Results for «{best.query}» (the analyst was unavailable, so these are unreviewed):", ""]
        n = 0
        for r in best.result.runs:
            for h in r.hits[:2]:
                price = f" — {h.price_toman:,} Toman" if h.price_toman else ""
                lines.append(f"- **{h.title}**{price} ({r.title})")
                n += 1
        if not n:
            lines.append("No service returned results.")
        return "\n".join(lines)
