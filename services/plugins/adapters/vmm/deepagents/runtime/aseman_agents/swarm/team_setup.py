"""Setting up a team for a goal: reuse first, generate only what is missing.

The lead's team comes from three places, in this order of preference: the
space's own agents, agents published in the marketplace (hired into the
space), and specialists written for the goal (recruited). The language model
and the decision model each do what they are good at:

1. roles — the language model breaks the goal into the roles it needs, each
   with what it must deliver (one call);
2. shortlist — every role's candidates are narrowed by what their profiles
   share with the role (no model);
3. scoring — the decision model rates every shortlisted (role, candidate) pair
   in one fast request, with probabilities;
4. picks — a confident, clear winner is taken as is; a close or middling call
   goes to the language model, which settles every such role in one call; a
   role nothing fits is left for a new agent;
5. generation — the language model writes the missing specialists (one call)
   and the decision model checks each fits its role (one request); one that
   does not is written once more with that feedback.

Without a decision model the language model does the scoring too. Without
either (both failed) the shortlist alone picks, and nothing is generated that
the model did not write.
"""

from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass, field
from typing import Any

from .. import team as teamlib
from ..context import TurnContext
from ..decision.client import probability
from ..gateway import GatewayError
from . import llm, market

log = logging.getLogger("aseman.agents.swarm")

#: At most this many roles in a team.
MAX_ROLES = 6
#: Candidates per role shown to the decision model.
SHORTLIST = 6
#: A decision-model score at or above this, clearly ahead of the next, is a pick.
ACCEPT = 0.7
#: The lead must be ahead of the runner-up by this much to be clear.
MARGIN = 0.15
#: Below this nobody fits: the role gets a new agent.
CONSIDER = 0.35
#: The space's own agents get this edge over equal market candidates.
SPACE_BONUS = 0.05
#: A generated specialist that fits its role with less than this is rewritten once.
SPEC_FITS = 0.5

_KEY = re.compile(r"[^a-z0-9]+")


@dataclass
class Role:
    key: str
    title: str
    needs: str
    instances: int = 1


@dataclass
class Pick:
    role: Role
    candidate: market.Candidate | None = None
    confidence: float = 0.0
    how: str = ""  # decision model | language model | shortlist | generated
    member: teamlib.Member | None = None
    error: str = ""


@dataclass
class Team:
    goal: str
    picks: list[Pick] = field(default_factory=list)

    def members(self) -> list[teamlib.Member]:
        return [p.member for p in self.picks if p.member is not None]

    def json(self) -> dict[str, Any]:
        return {"goal": self.goal, "roles": [
            {"role": p.role.key, "title": p.role.title, "needs": p.role.needs, "instances": p.role.instances,
             "agent": p.member.name if p.member else "", "account_id": p.member.account_id if p.member else "",
             "source": (p.candidate.source if p.candidate else ("generated" if p.member else "")),
             "how": p.how, "confidence": round(p.confidence, 2), "error": p.error}
            for p in self.picks]}

    def describe(self) -> str:
        lines = [f"Team for: {self.goal}"]
        origins = {"space": "already in the space", "hired": "hired from the marketplace",
                   "market": "from the marketplace"}
        for p in self.picks:
            if p.member is None:
                lines.append(f"- {p.role.title} → nobody ({p.error or 'no agent'})")
                continue
            origin = origins.get(p.candidate.source, p.candidate.source) if p.candidate else "new specialist"
            if p.candidate is not None:
                origin += f", picked by the {p.how} at {p.confidence:.2f}"
            line = f"- {p.role.title} → {p.member.name} ({origin})"
            if p.role.instances > 1:
                line += f", ×{p.role.instances} in parallel"
            lines.append(line)
        return "\n".join(lines)


def _slug(text: str) -> str:
    return _KEY.sub("-", text.lower()).strip("-")[:40] or "role"


# --- 1. roles ------------------------------------------------------------------

ROLES_SYSTEM = (
    "You staff a team of AI agents for a goal. Answer only in JSON. Name the distinct specialist roles the goal "
    "needs (at most {max}): each a craft with its own method, not a step of the plan. Small goals need one or two "
    "roles; do not invent roles for coordination, which the lead does itself. `instances` is how many agents of "
    "that role can usefully work in parallel on independent parts (1 unless the work splits cleanly).{development}"
)

# What the roles say about programming, by the node's OpenCode switch.
ROLES_OPENCODE = (
    " Never name a software development role (developer, engineer, programmer, coder, frontend, backend, "
    "full-stack, devops, code tester or reviewer): all programming is done by OpenCode, which the lead briefs "
    "directly, so staff only what the code needs from people's side (research, content, data, design decisions)."
)
ROLES_AGENTS = (
    " Software is built by the team's own agents: when the goal needs code, name one software developer role "
    "per project it builds (an app, a service, a script) — one owner per project, never two roles for the same "
    "code — and staff what the code needs from people's side (research, content, data, design decisions) as "
    "roles of their own."
)

# Development roles the model may still name while OpenCode is on: programming
# is then OpenCode's alone (see prompts._DEVELOPMENT), so they are never
# staffed with agents. Off, they are staffed like any other role.
_DEV_ROLE = re.compile(
    r"\b(developers?|(software|game) development|programm(er|ing)|coder|coding|software|front[- ]?end|back[- ]?end|full[- ]?stack|"
    r"devops|sre|web ?dev\w*|app ?dev\w*|(data|qa|ml|platform|cloud|site reliability) engineer)\b", re.I)
_CODE = re.compile(r"\b(code|coding|program\w*|script\w*|software|api|app|website)\b", re.I)


def development_role(title: str, needs: str = "") -> bool:
    """Whether a role is software development (OpenCode's, never an agent's).
    A bare "engineer" counts only when what it must deliver is code."""
    if _DEV_ROLE.search(title):
        return True
    return bool(re.search(r"\bengineer", title, re.I) and _CODE.search(needs)) or \
        bool(_DEV_ROLE.search(needs) and _CODE.search(needs) and re.search(r"\b(write|build|implement|fix)", needs, re.I))


async def roles_for(ctx: TurnContext, goal: str, max_roles: int) -> list[Role]:
    development = ROLES_OPENCODE if ctx.opencode else ROLES_AGENTS
    answer = await llm.ask_json(ctx, ROLES_SYSTEM.format(max=max_roles, development=development), (
        f"Goal:\n{goal}\n\nAnswer as {{\"roles\": [{{\"key\": \"short-slug\", \"title\": \"Role title\", "
        "\"needs\": \"what this role must deliver for the goal, concretely\", \"instances\": 1}]}}"))
    roles: list[Role] = []
    seen: set[str] = set()
    for raw in (answer or {}).get("roles") or [] if isinstance(answer, dict) else []:
        if not isinstance(raw, dict) or not (raw.get("title") or raw.get("key")):
            continue
        key = _slug(str(raw.get("key") or raw.get("title")))
        if key in seen or (ctx.opencode and development_role(str(raw.get("title") or key), str(raw.get("needs") or ""))):
            continue
        seen.add(key)
        instances = raw.get("instances") or 1
        roles.append(Role(key=key, title=str(raw.get("title") or key), needs=str(raw.get("needs") or raw.get("title")),
                          instances=max(1, min(int(instances) if str(instances).isdigit() else 1, 8))))
        if len(roles) >= max_roles:
            break
    # Without an answer, the goal itself is the one role.
    return roles or [Role(key="specialist", title="Specialist", needs=goal)]


# --- 2-4. picks ------------------------------------------------------------------

def shortlist(role: Role, pool: list[market.Candidate], n: int = SHORTLIST) -> list[market.Candidate]:
    """The candidates whose profiles share most with the role (the space's own first on ties)."""
    ranked = sorted(pool, key=lambda c: (-market.overlap(role.title + " " + role.needs, c), c.source != "space",
                                         -c.installs))
    return ranked[:n]


async def score(ctx: TurnContext, goal: str, roles: list[Role],
                lists: dict[str, list[market.Candidate]]) -> dict[tuple[str, str], float] | None:
    """The decision model's probability that each candidate delivers each role."""
    if ctx.decision is None:
        return None
    questions: dict[str, Any] = {}
    index: dict[str, tuple[str, str]] = {}
    for i, role in enumerate(roles):
        for j, c in enumerate(lists.get(role.key) or []):
            qid = f"r{i}c{j}"
            index[qid] = (role.key, c.key)
            questions[qid] = {
                "type": "boolean",
                "instructions": (f"Can the agent `{c.name}` ({c.profile()}) deliver the role `{role.title}`: "
                                 f"{role.needs[:600]}?"),
                "criteria": {"true": "its profile shows the craft and the kind of deliverable the role needs",
                             "false": "it is a different craft, or too general or too narrow for the role"}}
    if not questions:
        return {}
    answers = await ctx.decision.evaluate({"goal": goal[-3000:]}, questions)
    if answers is None:
        return None
    out: dict[tuple[str, str], float] = {}
    for qid, pair in index.items():
        p = probability(answers, qid)
        if p is not None:
            out[pair] = p
    return out


ADJUDICATE_SYSTEM = (
    "You staff a team of AI agents. Answer only in JSON. For each role pick the one candidate that will deliver it "
    "best, or \"none\" when none of them really fits (a new specialist is then written for it). Prefer an agent "
    "already in the space when it fits as well as a marketplace one."
)


async def adjudicate(ctx: TurnContext, goal: str, roles: list[Role],
                     lists: dict[str, list[market.Candidate]]) -> dict[str, str] | None:
    """The language model's picks for roles the decision model could not settle."""
    if not roles:
        return {}
    blocks = []
    for role in roles:
        options = "\n".join(f"  - `{c.key}` ({c.source}): {c.profile()}" for c in lists.get(role.key) or [])
        blocks.append(f"Role `{role.key}` — {role.title}: {role.needs}\n{options or '  (no candidates)'}")
    answer = await llm.ask_json(ctx, ADJUDICATE_SYSTEM, (
        f"Goal:\n{goal}\n\n" + "\n\n".join(blocks)
        + "\n\nAnswer as {\"choices\": {\"<role key>\": \"<candidate key or none>\"}}"))
    choices = answer.get("choices") if isinstance(answer, dict) else None
    return {str(k): str(v) for k, v in choices.items()} if isinstance(choices, dict) else None


async def pick(ctx: TurnContext, goal: str, roles: list[Role], pool: list[market.Candidate]) -> list[Pick]:
    lists = {role.key: shortlist(role, pool) for role in roles}
    by_key = {c.key: c for c in pool}
    picks = {role.key: Pick(role=role) for role in roles}
    scores = await score(ctx, goal, roles, lists)
    unsettled: list[Role] = []
    if scores is None:
        unsettled = list(roles)  # no decision model: the language model picks every role
    else:
        for role in roles:
            ranked = sorted(((scores.get((role.key, c.key), 0.0) + (SPACE_BONUS if c.source == "space" else 0.0), c)
                             for c in lists[role.key]), key=lambda x: -x[0])
            best = ranked[0] if ranked else (0.0, None)
            second = ranked[1][0] if len(ranked) > 1 else 0.0
            if best[1] is not None and best[0] >= ACCEPT and (best[0] - second >= MARGIN or second < ACCEPT):
                picks[role.key] = Pick(role=role, candidate=best[1], confidence=min(1.0, best[0]), how="decision model")
            elif best[1] is not None and best[0] >= CONSIDER:
                # Middling, or two close calls: the language model reads them.
                lists[role.key] = [c for _, c in ranked[:3]]
                picks[role.key].confidence = min(1.0, best[0])
                unsettled.append(role)
            # Otherwise nobody fits: the role is left for a new agent.
    if unsettled:
        choices = await adjudicate(ctx, goal, unsettled, lists)
        for role in unsettled:
            choice = (choices or {}).get(role.key)
            if choices is None:
                # Neither model answered: the shortlist decides, when it found anything.
                top = lists[role.key][0] if lists[role.key] else None
                if top is not None and market.overlap(role.title + " " + role.needs, top) >= 0.34:
                    picks[role.key] = Pick(role=role, candidate=top, confidence=0.3, how="shortlist")
            elif choice and choice != "none" and choice in by_key:
                picks[role.key] = Pick(role=role, candidate=by_key[choice],
                                       confidence=picks[role.key].confidence or 0.6, how="language model")
    return [picks[role.key] for role in roles]


# --- 5. generation ------------------------------------------------------------------

WRITE_SYSTEM = (
    "You write AI specialist agents for a team. Answer only in JSON. Each agent gets a short role name, a one-line "
    "description of what it is good at, and instructions: its way of working, its standards and what a finished "
    "deliverable looks like (do not repeat platform basics such as how to message or use the computer). Give a "
    "skill only for a recurring procedure with a recognisable trigger."
)


def _spec_ok(raw: Any) -> bool:
    return isinstance(raw, dict) and bool(str(raw.get("name") or "").strip()) and bool(
        str(raw.get("instructions") or "").strip())


async def write_specs(ctx: TurnContext, goal: str, roles: list[Role], feedback: dict[str, str] | None = None) -> dict[str, dict[str, Any]]:
    if not roles:
        return {}
    lines = []
    for r in roles:
        line = f"- `{r.key}` — {r.title}: {r.needs}"
        if feedback and feedback.get(r.key):
            line += f"\n  The previous draft fell short: {feedback[r.key]}"
        lines.append(line)
    answer = await llm.ask_json(ctx, WRITE_SYSTEM, (
        f"Goal:\n{goal}\n\nWrite one agent for each role:\n" + "\n".join(lines)
        + "\n\nAnswer as {\"agents\": [{\"role\": \"<role key>\", \"name\": \"role-name\", \"description\": \"...\", "
        "\"instructions\": \"...\", \"skills\": [{\"name\": \"...\", \"description\": \"...\", \"instructions\": \"...\"}]}]}"))
    out: dict[str, dict[str, Any]] = {}
    for raw in (answer.get("agents") or []) if isinstance(answer, dict) else []:
        if _spec_ok(raw) and str(raw.get("role")) in {r.key for r in roles}:
            out[str(raw["role"])] = raw
    return out


async def check_specs(ctx: TurnContext, roles: list[Role], specs: dict[str, dict[str, Any]]) -> dict[str, str]:
    """Roles whose written specialist the decision model finds unfit, with why."""
    if ctx.decision is None or not specs:
        return {}
    questions = {}
    for i, role in enumerate(roles):
        spec = specs.get(role.key)
        if spec is None:
            continue
        questions[f"s{i}"] = {
            "type": "boolean",
            "instructions": (f"Will an agent with these instructions deliver the role `{role.title}` ({role.needs[:500]})?\n"
                             f"Description: {str(spec.get('description', ''))[:300]}\n"
                             f"Instructions: {str(spec.get('instructions', ''))[:2500]}"),
            "criteria": {"true": "the instructions cover the craft, the method and what done looks like for the role",
                         "false": "they are generic, off-role, or miss what the role must deliver"}}
    answers = await ctx.decision.evaluate({"roles": [r.title for r in roles]}, questions)
    unfit = {}
    for i, role in enumerate(roles):
        p = probability(answers, f"s{i}")
        if p is not None and p < SPEC_FITS:
            unfit[role.key] = f"an independent check rated its fit for the role at {p:.2f}: make it specific to the role"
    return unfit


async def recruit(ctx: TurnContext, spec: dict[str, Any]) -> teamlib.Member:
    skills = [{"name": str(s.get("name")), "description": str(s.get("description") or ""),
               "instructions": str(s.get("instructions") or "")}
              for s in spec.get("skills") or [] if isinstance(s, dict) and s.get("name") and s.get("instructions")]
    out = await ctx.gateway.call("spaces", "agent_recruit", {
        "space": ctx.space, "room": ctx.room, "name": str(spec["name"])[:40],
        "description": str(spec.get("description") or "")[:500], "instructions": str(spec["instructions"]),
        "skills": skills or None,
    })
    return teamlib.Member(account_id=out["account_id"], name=out["name"], kind="agent", bot_id=out.get("bot_id", ""),
                          description=str(spec.get("description") or ""), runtime=True)


# --- the whole setup ------------------------------------------------------------------

async def assemble(ctx: TurnContext, goal: str, *, max_roles: int = MAX_ROLES, generate: bool = True) -> Team:
    """Staff a team for the goal (see the module docstring)."""
    members = await teamlib.team(ctx)
    roles, pool = await asyncio.gather(roles_for(ctx, goal, max_roles), market.candidates(ctx, members))
    picks = await pick(ctx, goal, roles, pool)
    team = Team(goal=goal, picks=picks)
    # Reuse: bring in the marketplace picks (several roles may share one agent).
    hired: dict[str, teamlib.Member] = {}
    for p in picks:
        if p.candidate is None:
            continue
        try:
            if p.candidate.key not in hired:
                hired[p.candidate.key] = await market.hire(ctx, p.candidate)
            p.member = hired[p.candidate.key]
        except (GatewayError, KeyError) as exc:
            log.warning("hiring %s failed: %s", p.candidate.name, exc)
            p.error = f"could not hire {p.candidate.name}: {exc}"
            p.candidate = None
    missing = [p.role for p in picks if p.member is None]
    if missing and generate:
        specs = await write_specs(ctx, goal, missing)
        unfit = await check_specs(ctx, missing, specs)
        if unfit:
            again = await write_specs(ctx, goal, [r for r in missing if r.key in unfit], feedback=unfit)
            specs.update(again)
        for p in picks:
            if p.member is not None or p.role.key not in specs:
                continue
            try:
                p.member = await recruit(ctx, specs[p.role.key])
                p.how, p.confidence, p.error = "generated", 1.0, ""
            except (GatewayError, KeyError) as exc:
                p.error = f"could not recruit: {exc}"
    log.info("team for %r: %s", goal[:80], [(p.role.key, p.member.name if p.member else None, p.how) for p in picks])
    return team
