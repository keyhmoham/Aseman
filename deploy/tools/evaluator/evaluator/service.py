"""The evaluator's microtools and its background worker.

Read microtools (anyone the node lets ask — the node's public
tools.traders_leaderboard / tools.trader_profile forward only these):
  leaderboard, trader_get, traders_list, status

Admin microtools (only from a space the tool was added to — the admins
space):
  trader_add, trader_remove, trader_credentials, evaluate_now, configure,
  set_session, tick

Adding a trader makes them an ordinary account on this platform (their
CoinMarketCap handle or a username the admin picks, a random password the
evaluator keeps). The worker iterates the traders: each one whose last
evaluation is older than `interval_hours` (or that an admin queued) is
crawled with the browser, signed in as on the platform to upsert their
latest posts, measured against market data, analysed with decifi's prompt
and stored.
"""

from __future__ import annotations

import json
import threading
import time
import traceback
from datetime import datetime, timezone
from typing import Any, Callable

from . import crawler as crawler_mod
from . import llm as llm_mod
from . import market as market_mod
from . import platform as platform_mod
from .host import HostError, Node, Scope, ScopeKeeper
from .platform import Platform, PlatformError
from .prompt import build_objective, normalize_profile_url
from .scoring import BOARDS, extract_json, normalize
from .store import CONFIG, DEFAULT_CONFIG, SESSION, TRADER, TRADERS, Store, handle_of, valid_profile_link

READ_ONLY = ("leaderboard", "trader_get", "traders_list", "status")
MAX_PROMPT_DATA = 90_000
HISTORY = 30
ERROR_RETRY = 3600


class ToolError(Exception):
    pass


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _obj(props: dict, required: list[str] | None = None) -> dict:
    out: dict[str, Any] = {"type": "object", "properties": props}
    if required:
        out["required"] = required
    return out


S = {"type": "string"}
TOOLS = [
    {"name": "leaderboard",
     "description": "Traders ranked by their evaluated reliability scores. board: overall, technical, fundamental, accuracy, consistency, risk or timing.",
     "inputSchema": _obj({"board": {"type": "string", "enum": list(BOARDS)}, "limit": {"type": "integer", "minimum": 1, "maximum": 200}})},
    {"name": "trader_get", "description": "One trader's full reliability report, scores and evaluation history.",
     "inputSchema": _obj({"handle": S}, ["handle"])},
    {"name": "traders_list", "description": "Every trader on the list with its evaluation status.", "inputSchema": _obj({})},
    {"name": "status", "description": "The evaluator's worker, queue, settings and browser session state.", "inputSchema": _obj({})},
    {"name": "trader_add",
     "description": "Admin: add a trader by their CoinMarketCap community profile link (https://coinmarketcap.com/community/profile/<handle>/). It makes them a platform account (username: their CoinMarketCap handle, or `username`; a random password, see trader_credentials) and evaluates them right away.",
     "inputSchema": _obj({"profile_link": S, "name": S, "username": S}, ["profile_link"])},
    {"name": "trader_remove",
     "description": "Admin: remove a trader and their scores, and the platform account the evaluator made for them with the posts it published (keep_account: true keeps the account and its posts).",
     "inputSchema": _obj({"handle": S, "keep_account": {"type": "boolean"}}, ["handle"])},
    {"name": "trader_credentials", "description": "Admin: a trader's platform account: username, account id and password.",
     "inputSchema": _obj({"handle": S}, ["handle"])},
    {"name": "evaluate_now", "description": "Admin: queue a trader (or every trader, without handle) for evaluation now.",
     "inputSchema": _obj({"handle": S})},
    {"name": "configure",
     "description": "Admin: settings — interval_hours, max_posts, proxy, agent_bot, llm_base_url, llm_api_key, llm_model.",
     "inputSchema": _obj({"interval_hours": {"type": "number", "minimum": 1}, "max_posts": {"type": "integer", "minimum": 5, "maximum": 200},
                          "proxy": S, "agent_bot": S, "llm_base_url": S, "llm_api_key": S, "llm_model": S})},
    {"name": "set_session",
     "description": "Admin: the logged-in CoinMarketCap browser session — a Playwright storage_state (cookies + localStorage, from decifi's capture_cmc_session.py) or a cookie jar list (cmc_cookiejar.json).",
     "inputSchema": _obj({"storage_state": {"type": ["object", "string"]}, "cookies": {"type": ["array", "string"]}})},
    {"name": "tick", "description": "Heartbeat from the admins space routine: keeps the worker's scope fresh and starts due evaluations.",
     "inputSchema": _obj({})},
]


def summary_entry(rec: dict) -> dict:
    """A trader as the leaderboard shows them."""
    s = rec.get("summary") or {}
    analyst = rec.get("analyst") or {}
    report = rec.get("report") or {}
    hist = rec.get("history") or []
    account = rec.get("account") or {}
    change = None
    if len(hist) >= 2 and isinstance(hist[-1].get("overall_score"), (int, float)) and isinstance(hist[-2].get("overall_score"), (int, float)):
        change = round(hist[-1]["overall_score"] - hist[-2]["overall_score"], 1)
    return {
        "handle": rec.get("handle"), "name": rec.get("name") or analyst.get("nickname") or rec.get("handle"),
        "profile_link": rec.get("profile_link"), "avatar": analyst.get("avatar"),
        "followers": analyst.get("followers"), "total_posts": analyst.get("total_posts"),
        "posts_analyzed": rec.get("posts_analyzed"), "status": rec.get("status"),
        "last_evaluated_at": rec.get("last_evaluated_at"), "last_error": rec.get("last_error"),
        "change": change, "scores": {k: s.get(k) for k in ("overall_score", "technical_score", "fundamental_score",
                                                              "historical_accuracy", "consistency", "risk_management",
                                                              "timing", "confidence")},
        "rating": s.get("rating") or "Unrated",
        "strengths": (report.get("strengths") or [])[:3], "warnings": (report.get("warnings") or [])[:3],
        # The trader's account here (never its password).
        "platform_account": {k: account.get(k) for k in ("id", "handle")} if account else None,
    }


def rank(records: list[dict], board: str, limit: int) -> list[dict]:
    key = BOARDS.get(board, "overall_score")
    entries = [summary_entry(r) for r in records]

    def sort_key(e: dict):
        v = e["scores"].get(key)
        return (v is None, -(v or 0), -(e["scores"].get("confidence") or 0), e["handle"] or "")

    entries.sort(key=sort_key)
    for i, e in enumerate(entries, 1):
        e["rank"] = i if e["scores"].get(key) is not None else None
    return entries[:limit]


class Evaluator:
    def __init__(self, node: Node | None = None,
                 crawl: Callable[..., dict] = crawler_mod.crawl,
                 market: Callable[[list[dict]], dict] = market_mod.market_context,
                 analyse: Callable[..., tuple[str, str]] = llm_mod.analyse,
                 clock: Callable[[], float] = time.time,
                 platform: Platform | None = None):
        self.node = node or Node()
        self.platform = platform or Platform()
        self.scopes = ScopeKeeper()
        self.store = Store(self.node, self.scopes.kv)
        self.crawl, self.market, self.analyse, self.clock = crawl, market, analyse, clock
        self.queue: list[str] = []
        self.running: str | None = None
        self.last_cycle: dict[str, Any] = {}
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._stop = False

    # --- MCP entry -------------------------------------------------------------

    def call(self, name: str, args: dict, scope: Scope) -> Any:
        self.scopes.offer(scope)
        handler = getattr(self, "t_" + name, None)
        if handler is None or name not in {t["name"] for t in TOOLS}:
            raise ToolError(f"unknown microtool {name}")
        if name not in READ_ONLY and not scope.space:
            raise ToolError(f"{name} is an admin microtool: call it from the admins space")
        # Reads use this call's own scope; writes too (it is the freshest).
        store = Store(self.node, lambda: scope if scope.token else self.scopes.kv())
        return handler(store, args or {}, scope)

    # --- reads -----------------------------------------------------------------

    def t_leaderboard(self, store: Store, args: dict, scope: Scope) -> dict:
        board = str(args.get("board") or "overall").lower()
        if board not in BOARDS:
            raise ToolError(f"board is one of {', '.join(BOARDS)}")
        limit = max(1, min(200, int(args.get("limit") or 100)))
        records = store.traders()
        evaluated = [r for r in records if (r.get("summary") or {}).get("overall_score") is not None]
        updated = max((r.get("last_evaluated_at") or "" for r in records), default="") or None
        return {"board": board, "score_key": BOARDS[board], "traders": rank(records, board, limit),
                "total": len(records), "evaluated": len(evaluated), "updated_at": updated}

    def t_trader_get(self, store: Store, args: dict, scope: Scope) -> dict:
        handle = str(args.get("handle") or "").strip().lstrip("@").lower()
        rec = store.trader(handle) if handle else None
        if rec is None:
            raise ToolError(f"no trader {handle!r}")
        out = summary_entry(rec)
        out.update({"report": rec.get("report"), "history": rec.get("history") or [], "analyst": rec.get("analyst"),
                    "added_at": rec.get("added_at"), "analysed_by": rec.get("analysed_by"),
                    "posts_sync": rec.get("posts_sync")})
        return out

    def t_traders_list(self, store: Store, args: dict, scope: Scope) -> dict:
        return {"traders": [{k: summary_entry(r)[k] for k in ("handle", "name", "profile_link", "status",
                                                               "last_evaluated_at", "last_error", "platform_account")}
                            for r in store.traders()]}

    def t_status(self, store: Store, args: dict, scope: Scope) -> dict:
        cfg = store.config()
        cfg_view = {k: v for k, v in cfg.items() if k != "llm_api_key"}
        cfg_view["llm_api_key_set"] = bool(cfg.get("llm_api_key"))
        return {"running": self.running, "queue": list(self.queue), "last_cycle": self.last_cycle,
                "config": cfg_view, "session": crawler_mod.session_summary(store.get(SESSION)),
                "worker_scope_valid": self.scopes.kv() is not None,
                "agent_scope_valid": self.scopes.space() is not None}

    # --- admin -----------------------------------------------------------------

    def t_trader_add(self, store: Store, args: dict, scope: Scope) -> dict:
        link = normalize_profile_url(str(args.get("profile_link") or ""))
        if not valid_profile_link(link):
            raise ToolError("profile_link must be a CoinMarketCap community profile, e.g. https://coinmarketcap.com/community/profile/<handle>/")
        handle = handle_of(link)
        wanted = str(args.get("username") or "").strip().lstrip("@").lower()
        if wanted and (platform_mod.username_for(wanted) != wanted or not platform_mod.valid_username(wanted)):
            raise ToolError("username: 3-30 letters, digits, '.', '_' or '-', starting and ending with a letter or digit")
        rec = store.trader(handle)
        created = rec is None
        if rec is None:
            rec = {"handle": handle, "added_at": now_iso(), "added_by": scope.actor, "history": []}
        rec.update({"profile_link": link, "status": "queued"})
        if args.get("name"):
            rec["name"] = str(args["name"])[:80]
        account_note = None
        if rec.get("account") and wanted and wanted != rec["account"].get("handle"):
            account_note = f"kept the existing account @{rec['account']['handle']}"
        if not rec.get("account"):
            # Made before the trader is listed: a taken username fails the add.
            rec["account"] = self.make_account(scope, wanted or platform_mod.username_for(handle), rec.get("name") or "")
        store.put_trader(rec)
        handles = store.handles()
        if handle not in handles:
            store.set(TRADERS, handles + [handle])
        self.enqueue(handle)
        out = {"ok": True, "created": created, "trader": summary_entry(rec)}
        if account_note:
            out["note"] = account_note
        return out

    def t_trader_remove(self, store: Store, args: dict, scope: Scope) -> dict:
        handle = str(args.get("handle") or "").strip().lstrip("@").lower()
        handles = store.handles()
        rec = store.trader(handle)
        if handle not in handles and rec is None:
            raise ToolError(f"no trader {handle!r}")
        account = (rec or {}).get("account") or {}
        out: dict[str, Any] = {"ok": True, "removed": handle}
        if account and args.get("keep_account"):
            out["kept_account"] = dict(account)  # its password is not kept anywhere else
        elif account:
            out.update(self.delete_account(scope, account, (rec or {}).get("platform_posts") or {}))
        store.set(TRADERS, [h for h in handles if h != handle])
        store.delete(TRADER + handle)
        with self._lock:
            self.queue = [h for h in self.queue if h != handle]
        return out

    def t_trader_credentials(self, store: Store, args: dict, scope: Scope) -> dict:
        handle = str(args.get("handle") or "").strip().lstrip("@").lower()
        rec = store.trader(handle)
        if rec is None:
            raise ToolError(f"no trader {handle!r}")
        account = rec.get("account")
        if not account:
            raise ToolError(f"{handle} has no platform account yet: it is made on their next evaluation")
        return {"trader": handle, "username": account.get("handle"), "account_id": account.get("id"),
                "password": account.get("password"), "created_at": account.get("created_at")}

    # --- the traders' platform accounts -----------------------------------------

    def make_account(self, scope: Scope, username: str, name: str = "") -> dict:
        """A new platform account for a trader (users.account_create)."""
        password = platform_mod.new_password()
        try:
            out = self.node.call(scope, "users", "account_create",
                                 {"handle": username, "password": password, "display_name": name}, timeout=60)
        except HostError as e:
            if e.status == 409 or e.code.upper() == "ALREADY_EXISTS":
                raise ToolError(f"the username @{username} is taken on this platform: add the trader again with another `username`") from None
            raise ToolError(f"could not make the trader's account: {e}") from None
        return {"id": out.get("id"), "handle": out.get("handle") or username, "password": password, "created_at": now_iso()}

    def delete_account(self, scope: Scope, account: dict, published: dict) -> dict:
        """Deletes what the evaluator published as the trader, then their account."""
        out: dict[str, Any] = {}
        try:
            session = self.platform.login(account["handle"], account["password"])
            try:
                out["posts_deleted"] = platform_mod.delete_posts(self.platform, session, published)
            finally:
                self.platform.logout(session)
        except PlatformError as e:
            out["posts_error"] = str(e)
        try:
            self.node.call(scope, "users", "account_delete", {"account": account.get("id")}, timeout=60)
            out["account_deleted"] = account.get("handle")
        except HostError as e:
            if not e.not_found:
                raise ToolError(f"removed nothing: the trader's account @{account.get('handle')} could not be deleted ({e}); "
                                "remove with keep_account: true to keep it") from None
            out["account_deleted"] = account.get("handle")
        return out

    def sync_platform_posts(self, rec: dict, posts: list[dict]) -> dict:
        """Signs in as the trader and upserts their latest posts; the outcome."""
        account = rec.get("account") or {}
        if not account:
            scope = self.scopes.space()
            if scope is None:
                return {"at": now_iso(), "error": "the trader has no platform account yet (needs the admins space routine's scope)"}
            try:
                rec["account"] = account = self.make_account(scope, platform_mod.username_for(rec["handle"]), rec.get("name") or "")
            except ToolError as e:
                return {"at": now_iso(), "error": str(e)}
        try:
            session = self.platform.login(account["handle"], account["password"])
        except PlatformError as e:
            return {"at": now_iso(), "error": f"sign-in as @{account['handle']} failed: {e}"}
        try:
            published, counts = platform_mod.sync_posts(self.platform, session, posts, rec.get("platform_posts") or {})
        finally:
            self.platform.logout(session)
        rec["platform_posts"] = published
        return {"at": now_iso(), **counts}

    def t_evaluate_now(self, store: Store, args: dict, scope: Scope) -> dict:
        handle = str(args.get("handle") or "").strip().lstrip("@").lower()
        handles = [handle] if handle else store.handles()
        if handle and store.trader(handle) is None:
            raise ToolError(f"no trader {handle!r}")
        for h in handles:
            rec = store.trader(h)
            if rec and rec.get("status") != "running":
                rec["status"] = "queued"
                store.put_trader(rec)
            self.enqueue(h)
        return {"ok": True, "queued": handles}

    def t_configure(self, store: Store, args: dict, scope: Scope) -> dict:
        cfg = store.get(CONFIG, {}) or {}
        for key in DEFAULT_CONFIG:
            if key in args and args[key] is not None:
                cfg[key] = args[key]
        if "interval_hours" in cfg:
            cfg["interval_hours"] = max(1.0, float(cfg["interval_hours"]))
        if "max_posts" in cfg:
            cfg["max_posts"] = max(5, min(200, int(cfg["max_posts"])))
        store.set(CONFIG, cfg)
        return self.t_status(store, {}, scope)["config"]

    def t_set_session(self, store: Store, args: dict, scope: Scope) -> dict:
        value = args.get("storage_state")
        if value in (None, ""):
            value = args.get("cookies")
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except Exception:
                raise ToolError("the session must be JSON: a storage_state object or a cookie list") from None
        state, cookies = crawler_mod.load_session(value)
        if state is None and cookies is None:
            raise ToolError("no session: pass storage_state {cookies, origins} or a cookie list")
        store.set(SESSION, state if state is not None else cookies)
        return crawler_mod.session_summary(state if state is not None else cookies)

    def t_tick(self, store: Store, args: dict, scope: Scope) -> dict:
        self.ensure_worker()
        self._wake.set()
        return {"ok": True, "running": self.running, "queue": list(self.queue), "last_cycle": self.last_cycle}

    # --- worker ----------------------------------------------------------------

    def enqueue(self, handle: str) -> None:
        with self._lock:
            if handle != self.running and handle not in self.queue:
                self.queue.append(handle)
        self.ensure_worker()
        self._wake.set()

    def ensure_worker(self) -> None:
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._loop, name="evaluator-worker", daemon=True)
                self._thread.start()

    def stop(self) -> None:
        self._stop = True
        self._wake.set()

    def _loop(self) -> None:
        while not self._stop:
            try:
                if self.scopes.kv() is not None:
                    self.run_due()
            except Exception as exc:  # keep serving; the next tick retries
                self.last_cycle = {"at": now_iso(), "error": str(exc)}
            self._wake.wait(timeout=60)
            self._wake.clear()

    def next_due(self) -> str | None:
        with self._lock:
            if self.queue:
                return self.queue.pop(0)
        cfg = self.store.config()
        interval = float(cfg.get("interval_hours") or 12) * 3600
        oldest, pick = None, None
        for rec in self.store.traders():
            # Queued by an admin, or left running by a backend that restarted
            # (this worker runs one evaluation at a time, and none is running).
            if rec.get("status") in ("queued", "running"):
                return rec["handle"]
            last = rec.get("last_attempt_at") or rec.get("last_evaluated_at")
            ts = datetime.fromisoformat(last).timestamp() if last else 0.0
            # A failed evaluation is retried within the hour.
            wait = min(interval, ERROR_RETRY) if rec.get("status") == "error" else interval
            if self.clock() - ts >= wait and (oldest is None or ts < oldest):
                oldest, pick = ts, rec["handle"]
        return pick

    def run_due(self) -> int:
        """Evaluates due traders one after another; returns how many ran."""
        done = 0
        while not self._stop and self.scopes.kv() is not None:
            handle = self.next_due()
            if not handle:
                break
            self.evaluate(handle)
            done += 1
        return done

    def evaluate(self, handle: str) -> dict | None:
        store = self.store
        rec = store.trader(handle)
        if rec is None:
            return None
        self.running = handle
        started = now_iso()
        rec.update({"status": "running", "last_attempt_at": started})
        store.put_trader(rec)
        try:
            cfg = store.config()
            max_posts = int(cfg.get("max_posts") or 40)
            crawl = self.crawl(rec["profile_link"], handle, store.get(SESSION), cfg.get("proxy") or "",
                               scrolls=min(40, max(6, max_posts // 2)))
            posts = (crawl.get("posts") or [])[:max_posts]
            if not posts and not (crawl.get("page_text") or "").strip():
                raise ToolError("the profile showed nothing: " + ("; ".join(crawl.get("errors") or []) or "empty page"))
            if crawl.get("logged_out_or_missing"):
                raise ToolError("CoinMarketCap says this account doesn't exist — the browser session is logged out or expired; upload a fresh one with set_session")
            # The trader's latest posts, the ones this round reads, on their platform account.
            rec["posts_sync"] = self.sync_platform_posts(rec, posts)
            store.put_trader(rec)
            market = self.market(posts)
            prompt = self.prompt(rec["profile_link"], crawl, posts, market)
            reply, by = self.analyse(self.node, self.scopes.space(), cfg, prompt)
            report = extract_json(reply)
            if not report:
                raise ToolError("the analysis did not return the Final JSON: " + (reply or "")[:300])
            report, summary = normalize(report)
            rec = store.trader(handle) or rec  # an admin may have renamed it meanwhile
            analyst = dict(rec.get("analyst") or {})
            analyst.update({k: v for k, v in (crawl.get("analyst") or {}).items() if v is not None})
            history = (rec.get("history") or []) + [{"at": now_iso(), **{k: summary.get(k) for k in ("overall_score", "technical_score", "fundamental_score", "confidence")}}]
            rec.update({"status": "done", "report": report, "summary": summary, "analyst": analyst,
                        "posts_analyzed": len(posts), "last_evaluated_at": now_iso(), "last_error": None,
                        "analysed_by": by, "history": history[-HISTORY:]})
            store.put_trader(rec)
            self.last_cycle = {"at": now_iso(), "handle": handle, "ok": True, "overall_score": summary.get("overall_score")}
            return rec
        except Exception as exc:
            msg = str(exc) if isinstance(exc, (ToolError, HostError)) else f"{type(exc).__name__}: {exc}"
            if not isinstance(exc, (ToolError, HostError)):
                traceback.print_exc()
            try:
                rec = store.trader(handle) or rec
                rec.update({"status": "error", "last_error": msg[:500]})
                store.put_trader(rec)
            except Exception:
                pass
            self.last_cycle = {"at": now_iso(), "handle": handle, "ok": False, "error": msg[:500]}
            return None
        finally:
            self.running = None

    @staticmethod
    def prompt(profile_link: str, crawl: dict, posts: list[dict], market: dict) -> str:
        """decifi's objective for this profile, with what the browser and the market data found."""
        data = {"analyst": crawl.get("analyst") or {}, "posts": posts, "market_data": market}
        if not posts:
            data["rendered_profile_text"] = crawl.get("page_text") or ""
        blob = json.dumps(data, ensure_ascii=False, default=str)
        if len(blob) > MAX_PROMPT_DATA:
            blob = blob[:MAX_PROMPT_DATA] + " …(truncated)"
        return (build_objective(profile_link)
                + "\n\nEVALUATOR DATA\n"
                  "The evaluator tool has already navigated to that profile with its browser tool and fetched the "
                  "posts below (newest first), together with the verifiable market data for every coin they name "
                  "(daily OHLCV outcomes after each post, keyed by post id, and the Fear & Greed index). Use only "
                  "this data; where something is missing, reduce confidence instead of guessing. Answer with the "
                  "STEP 15 Final JSON object only, every score 0-100.\n"
                + blob)
