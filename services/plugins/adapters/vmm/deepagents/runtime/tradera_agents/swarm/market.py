"""Who could join a team: the space's own agents and the marketplace's.

The marketplace is the node's catalog of published agents (``market.catalog``,
active listings only). An agent from it joins the space when it is hired
(``spaces.agent_hire``): it keeps its owner's definition and pricing, so the
lead reuses a proven specialist rather than writing a new one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from .. import team as teamlib
from ..context import TurnContext
from ..gateway import GatewayError

_KEY = re.compile(r"[^a-z0-9]+")
_WORD = re.compile(r"[a-z0-9]{3,}")
_STOP = frozenset({"the", "and", "for", "with", "that", "this", "from", "into", "your", "you", "are", "can",
                   "will", "who", "what", "its", "their", "about", "work", "agent", "agents", "task", "tasks"})


@dataclass
class Candidate:
    """An agent that could take a role."""

    key: str
    name: str
    description: str
    source: str  # "space" (already in the space) or "market" (hired on pick)
    member: teamlib.Member | None = None
    listing_id: str = ""
    bot_id: str = ""
    category: str = ""
    usecases: list[str] = field(default_factory=list)
    price: int = 0
    installs: int = 0

    def profile(self, n: int = 400) -> str:
        text = self.description.strip() or self.name
        if self.usecases:
            text += " Good for: " + "; ".join(self.usecases[:6]) + "."
        if self.category:
            text += f" ({self.category})"
        return " ".join(text.split())[:n]


def _key(name: str, taken: set[str]) -> str:
    base = _KEY.sub("-", name.lower()).strip("-")[:40] or "agent"
    key, n = base, 2
    while key in taken:
        key, n = f"{base}-{n}", n + 1
    taken.add(key)
    return key


def words(text: str) -> set[str]:
    return {w for w in _WORD.findall(text.lower()) if w not in _STOP}


def overlap(need: str, candidate: Candidate) -> float:
    """How much a candidate's profile shares with what a role needs (0..1)."""
    want = words(need)
    if not want:
        return 0.0
    have = words(candidate.name + " " + candidate.profile(1000))
    return len(want & have) / len(want)


async def market_agents(ctx: TurnContext, exclude: set[str]) -> list[dict[str, Any]]:
    """The marketplace's active agent listings, minus the given bot/account ids."""
    try:
        out = await ctx.gateway.call("market", "catalog", {"status": "active"})
    except GatewayError:
        return []
    rows = []
    for row in out.get("items") or []:
        bot = row.get("bot") or {}
        listing = row.get("listing") or {}
        if row.get("builtin") or (row.get("kind") or bot.get("kind")) != "agent":
            continue
        if str(row.get("status") or listing.get("status")) != "active" or not listing.get("id"):
            continue
        if {bot.get("id"), bot.get("account_id"), listing.get("bot_id")} & exclude:
            continue
        rows.append(row)
    return rows


async def candidates(ctx: TurnContext, members: list[teamlib.Member]) -> list[Candidate]:
    """Every agent that could join the team: the space's (but the lead) first."""
    taken: set[str] = set()
    out: list[Candidate] = []
    for m in members:
        if m.kind == "agent" and m.runtime and not m.lead:
            out.append(Candidate(key=_key(m.name, taken), name=m.name, description=m.description, source="space",
                                 member=m, bot_id=m.bot_id))
    exclude = {x for m in members for x in (m.bot_id, m.account_id) if x} | {ctx.agent.bot_id, ctx.agent.account_id}
    for row in await market_agents(ctx, exclude):
        bot, listing, d = row.get("bot") or {}, row.get("listing") or {}, row.get("descriptor") or {}
        name = str(d.get("name") or listing.get("name") or bot.get("name") or "agent")
        usecases = [str(u) for u in d.get("usecases") or [] if u]
        out.append(Candidate(key=_key(name, taken), name=name, source="market",
                             description=str(row.get("description") or d.get("description") or listing.get("description") or ""),
                             listing_id=str(listing["id"]), bot_id=str(bot.get("id") or listing.get("bot_id") or ""),
                             category=str(listing.get("category") or d.get("category") or ""), usecases=usecases,
                             price=int(listing.get("price") or 0), installs=int(listing.get("installs") or 0)))
    return out


async def hire(ctx: TurnContext, candidate: Candidate) -> teamlib.Member:
    """Bring a marketplace agent into the space (a space agent is already in)."""
    if candidate.member is not None:
        return candidate.member
    out = await ctx.gateway.call("spaces", "agent_hire", {"space": ctx.space, "room": ctx.room,
                                                          "listing": candidate.listing_id})
    candidate.member = teamlib.Member(account_id=out["account_id"], name=out.get("name") or candidate.name,
                                      kind="agent", bot_id=out.get("bot_id", candidate.bot_id),
                                      description=out.get("description") or candidate.description, runtime=True)
    candidate.source = "hired"
    return candidate.member
