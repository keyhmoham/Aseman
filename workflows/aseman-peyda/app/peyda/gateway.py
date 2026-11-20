"""The iran-mcp gateway: a frame in, grouped results out.

Each iran-mcp server is its own stdio MCP process (`uvx <package>` upstream;
here the packages are installed in the project's venv, so a server starts in a
moment). The gateway keeps one connection per server warm for a while, asks
the servers a frame routes to in parallel, and reports every one honestly:
`ok`, `empty`, `skipped` (with what it needed), or `error`. It never fills a
gap with a guess; the agent decides what a gap means.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from .args import build_args, slot_of
from .catalog import Catalog, Service, ToolRoute
from .frame import QueryFrame, normalize_text
from .lexicon import has_word
from .hits import Hit, _parse_json, _record_list, attr, parse_hits, result_text

log = logging.getLogger("peyda.gateway")

Launcher = Callable[[Service], StdioServerParameters]


def describe(e: BaseException) -> str:
    """An error as one line; the SDK's task groups wrap the real cause in an ExceptionGroup."""
    if isinstance(e, BaseExceptionGroup):
        return "; ".join(describe(x) for x in e.exceptions)[:300]
    return f"{type(e).__name__}: {e}"[:300]


# --------------------------------------------------------------------------
# One warm connection
# --------------------------------------------------------------------------

class Connection:
    """A server process and its MCP session, owned by one background task
    (anyio scopes must be entered and left by the same task)."""

    def __init__(self, service: Service, params: StdioServerParameters, startup: float, idle: float) -> None:
        self.service = service
        self.params = params
        self.tools: dict[str, dict[str, Any]] = {}
        self.error = ""
        self.last_used = time.monotonic()
        self._startup = startup
        self._idle = idle
        self._jobs: asyncio.Queue[tuple[asyncio.Future, str, dict[str, Any], float] | None] = asyncio.Queue()
        self._ready = asyncio.Event()
        self._task = asyncio.create_task(self._run(), name=f"mcp-{service.id}")

    async def _run(self) -> None:
        try:
            async with stdio_client(self.params) as (read, write):
                async with ClientSession(read, write) as session:
                    await asyncio.wait_for(session.initialize(), self._startup)
                    listed = await asyncio.wait_for(session.list_tools(), self._startup)
                    self.tools = {t.name: (attr(t, "inputSchema", "input_schema") or {}) for t in listed.tools}
                    self._ready.set()
                    while True:
                        try:
                            job = await asyncio.wait_for(self._jobs.get(), self._idle)
                        except asyncio.TimeoutError:
                            break  # idle: let the process go
                        if job is None:
                            break
                        fut, name, args, timeout = job
                        self.last_used = time.monotonic()
                        try:
                            result = await asyncio.wait_for(session.call_tool(name, args), timeout)
                            if not fut.cancelled():
                                fut.set_result(result)
                        except Exception as e:  # noqa: BLE001 - delivered to the caller
                            if not fut.cancelled():
                                fut.set_exception(e)
        except Exception as e:  # noqa: BLE001
            self.error = describe(e)
            log.warning("%s: connection ended: %s", self.service.id, self.error)
        finally:
            self.error = self.error or "closed"
            self._ready.set()
            while not self._jobs.empty():  # fail what is still waiting
                job = self._jobs.get_nowait()
                if job and not job[0].done():
                    job[0].set_exception(RuntimeError(self.error))

    @property
    def alive(self) -> bool:
        return not self._task.done()

    async def ready(self) -> None:
        await asyncio.wait_for(self._ready.wait(), self._startup + 5)
        if not self.alive and not self.tools:
            raise RuntimeError(self.error or "the server did not start")

    async def call(self, name: str, args: dict[str, Any], timeout: float) -> Any:
        if not self.alive:
            raise RuntimeError(self.error or "the server is not running")
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        await self._jobs.put((fut, name, args, timeout))
        return await fut

    async def close(self) -> None:
        if self.alive:
            await self._jobs.put(None)
            try:
                await asyncio.wait_for(self._task, 5)
            except Exception:  # noqa: BLE001
                self._task.cancel()


# --------------------------------------------------------------------------
# Launching servers
# --------------------------------------------------------------------------

def default_launcher(proxy: str = "") -> Launcher:
    """Installed console script first (PEYDA_MCP_BIN_DIR, else the services
    environment, else next to this interpreter), then `uvx <package>` as upstream documents."""
    services_venv = Path(os.environ.get("PEYDA_SERVICES_VENV", "/workspace/.venvs/iran-mcp")) / "bin"
    bin_dir = Path(os.environ.get("PEYDA_MCP_BIN_DIR") or (services_venv if services_venv.is_dir() else Path(sys.executable).parent))

    def launch(service: Service) -> StdioServerParameters:
        exe = bin_dir / service.package
        env = {"PYTHONUNBUFFERED": "1"}
        if proxy and service.proxy_env:
            env[service.proxy_env] = proxy
        if exe.exists():
            return StdioServerParameters(command=str(exe), args=[], env=env)
        uvx = shutil.which("uvx")
        if uvx:
            return StdioServerParameters(command=uvx, args=[service.package], env=env)
        raise FileNotFoundError(f"{service.package} is not installed (no {exe} and no uvx)")

    return launch


# --------------------------------------------------------------------------
# What a search returns
# --------------------------------------------------------------------------

@dataclass
class ServiceRun:
    id: str
    title: str
    status: str                       # ok | empty | skipped | error
    tool: str = ""
    args: dict[str, Any] = field(default_factory=dict)
    ms: int = 0
    hits: list[Hit] = field(default_factory=list)
    reason: str = ""
    missing: list[str] = field(default_factory=list)

    def to_dict(self, with_hits: bool = True) -> dict[str, Any]:
        d: dict[str, Any] = {"id": self.id, "title": self.title, "status": self.status, "tool": self.tool,
                             "ms": self.ms, "reason": self.reason, "missing": self.missing, "count": len(self.hits)}
        if self.args:
            d["args"] = self.args
        if with_hits:
            d["hits"] = [h.to_dict() for h in self.hits]
        return d


@dataclass
class SearchResult:
    frame: QueryFrame
    runs: list[ServiceRun]
    ms: int = 0

    @property
    def total(self) -> int:
        return sum(len(r.hits) for r in self.runs)

    @property
    def score(self) -> float:
        """How good a round was, for comparing rounds: results, spread across
        services, and results that carry a price or a link."""
        s = 0.0
        for r in self.runs:
            n = min(len(r.hits), 5)
            s += n + (1.5 if n else 0) + 0.25 * sum(1 for h in r.hits[:5] if h.price_toman or h.url)
        return round(s, 2)

    @property
    def gaps(self) -> list[dict[str, Any]]:
        return [{"service": r.id, "missing": r.missing} for r in self.runs if r.missing]

    def to_dict(self, with_hits: bool = True) -> dict[str, Any]:
        return {"frame": self.frame.to_dict(), "total": self.total, "score": self.score, "ms": self.ms,
                "services": [r.to_dict(with_hits) for r in self.runs], "gaps": self.gaps}

    def digest(self, per_service: int = 3) -> dict[str, Any]:
        """What the agent reads: every service's status and its best few hits."""
        return {
            "frame": self.frame.brief(), "total": self.total, "score": self.score,
            "assumptions": self.frame.assumptions,
            "services": [
                {"id": r.id, "title": r.title, "status": r.status, "reason": r.reason, "missing": r.missing,
                 "hits": [{k: v for k, v in h.to_dict().items() if k in ("title", "price_toman", "detail", "url")}
                          for h in r.hits[:per_service]]}
                for r in self.runs
            ],
        }


# --------------------------------------------------------------------------
# The gateway
# --------------------------------------------------------------------------

_CODE_KEYS = ("code", "iata", "airport_code", "station_code", "city_code", "id", "city_id", "slug", "place_id", "key", "value")


_PLACE_LISTS = ("airports", "stations", "cities", "places")
_SPECIALTY_LISTS = ("specialties", "specialities")


def pick_code(result: Any, *, want: str | None = None, lists: tuple[str, ...] = (), avoid: tuple[str, ...] = ()) -> str | None:
    """The first code-like value of a lookup (an IATA code, a station id, a slug).
    `want="slug"` prefers the slug over an id; `lists` names the answer's lists to
    read first (a suggest tool answers cities and specialties together)."""
    text = result_text(result)
    data = _parse_json(text)
    recs = None
    if isinstance(data, dict):
        for name in lists:
            v = data.get(name)
            if isinstance(v, list) and v and isinstance(v[0], dict):
                recs = v
                break
        if recs is None and avoid:
            data = {k: v for k, v in data.items() if k not in avoid}
    if recs is None:
        recs = _record_list(data) if data is not None else None
    if recs is None and isinstance(data, dict):
        recs = [data]
    keys = (("slug",) + tuple(k for k in _CODE_KEYS if k != "slug")) if want == "slug" else _CODE_KEYS
    for rec in recs or []:
        for k in keys:
            if rec.get(k) not in (None, "", [], {}):
                return str(rec[k])
    m = re.search(r"\b[A-Z]{3}\b", text)
    return m.group(0) if m else None


def find_coords(result: Any) -> tuple[float, float] | None:
    text = result_text(result)
    data = _parse_json(text)

    def walk(o: Any) -> tuple[float, float] | None:
        if isinstance(o, dict):
            low = {str(k).lower(): v for k, v in o.items()}
            lat = next((low[k] for k in ("lat", "latitude") if isinstance(low.get(k), (int, float))), None)
            lon = next((low[k] for k in ("lon", "lng", "longitude") if isinstance(low.get(k), (int, float))), None)
            if lat is not None and lon is not None:
                return float(lat), float(lon)
            for v in o.values():
                if (r := walk(v)):
                    return r
        elif isinstance(o, list):
            for v in o:
                if (r := walk(v)):
                    return r
        return None

    if data is not None and (r := walk(data)):
        return r
    m = re.search(r"lat\w*\W+(-?\d+\.\d+)\W+(?:lon|lng)\w*\W+(-?\d+\.\d+)", text, re.I)
    return (float(m.group(1)), float(m.group(2))) if m else None


_DOCTOR_WORDS = ("دکتر", "متخصص", "پزشک", "فوق تخصص", "doctor", "dr")


def _clean_specialty(text: str) -> str:
    """"دکتر پوست" → "پوست": a suggest tool matches the field, not the title."""
    out = text.strip()
    for w in _DOCTOR_WORDS:
        out = re.sub(rf"(^|\s){re.escape(w)}(?=\s|$)", " ", out, flags=re.I)
    return re.sub(r"\s+", " ", out).strip()


class Gateway:
    def __init__(
        self,
        catalog: Catalog,
        launcher: Launcher | None = None,
        *,
        max_parallel: int | None = None,
        tool_timeout: float | None = None,
        startup_timeout: float | None = None,
        idle_seconds: float | None = None,
        default_city: str | None = None,
    ) -> None:
        self.catalog = catalog
        self.launcher = launcher or default_launcher(os.environ.get("PEYDA_IRAN_PROXY", ""))
        self.sem = asyncio.Semaphore(max_parallel or int(os.environ.get("PEYDA_MAX_PARALLEL", "8")))
        self.tool_timeout = tool_timeout or float(os.environ.get("PEYDA_TOOL_TIMEOUT", "30"))
        self.startup_timeout = startup_timeout or float(os.environ.get("PEYDA_STARTUP_TIMEOUT", "90"))
        self.idle = idle_seconds or float(os.environ.get("PEYDA_IDLE_SECONDS", "600"))
        self.default_city = default_city if default_city is not None else os.environ.get("PEYDA_DEFAULT_CITY", "تهران")
        self._conns: dict[str, Connection] = {}
        self._lock = asyncio.Lock()
        self._resolved: dict[tuple[str, str], str | None] = {}
        self._coords: dict[tuple[str, str], tuple[float, float] | None] = {}

    # -- connections ------------------------------------------------------
    async def _connection(self, service: Service) -> Connection:
        async with self._lock:
            conn = self._conns.get(service.id)
            if conn is None or not conn.alive:
                conn = Connection(service, self.launcher(service), self.startup_timeout, self.idle)
                self._conns[service.id] = conn
        await conn.ready()
        return conn

    async def close(self) -> None:
        conns, self._conns = list(self._conns.values()), {}
        await asyncio.gather(*(c.close() for c in conns), return_exceptions=True)

    def status(self) -> dict[str, Any]:
        return {"services": len(self.catalog.services),
                "warm": sorted(i for i, c in self._conns.items() if c.alive and c.tools)}

    # -- helpers a tool may need first -----------------------------------
    async def _lookup(self, conn: Connection, tool: str, text: str, frame: QueryFrame, extra: dict[str, Any] | None = None) -> Any:
        schema = conn.tools.get(tool)
        if schema is None:
            return None
        probe = QueryFrame(text=text, normalized=normalize_text(text), slots={"product": text, "city": text})
        args, _ = build_args(schema, probe, limit=5)
        args.update(extra or {})  # what only the route knows: a lookup's mode
        return await conn.call(tool, args, self.tool_timeout)

    async def _resolve(self, conn: Connection, service: Service, text: str, frame: QueryFrame, *,
                       tool: str = "", want: str | None = None, extra: dict[str, Any] | None = None, kind: str = "place") -> str | None:
        tool = tool or service.resolve
        key = (service.id, kind, text, want or "", json.dumps(extra or {}, sort_keys=True))
        if key not in self._resolved:
            try:
                found = await self._lookup(conn, tool, text, frame, extra)
                if kind == "specialty":
                    self._resolved[key] = pick_code(found, want=want, lists=_SPECIALTY_LISTS)
                else:
                    self._resolved[key] = pick_code(found, want=want, lists=_PLACE_LISTS, avoid=_SPECIALTY_LISTS)
            except Exception as e:  # noqa: BLE001
                log.info("%s: could not resolve %r: %s", service.id, text, e)
                self._resolved[key] = None
        return self._resolved[key]

    async def _geocode(self, conn: Connection, service: Service, text: str, frame: QueryFrame) -> tuple[float, float] | None:
        key = (service.id, text)
        if key not in self._coords:
            try:
                self._coords[key] = find_coords(await self._lookup(conn, service.geocode, text, frame))
            except Exception as e:  # noqa: BLE001
                log.info("%s: could not geocode %r: %s", service.id, text, e)
                self._coords[key] = None
        return self._coords[key]

    # -- one service ------------------------------------------------------
    async def _run_service(self, service: Service, frame: QueryFrame, limit: int) -> ServiceRun:
        run = ServiceRun(id=service.id, title=service.title, status="skipped")
        started = time.monotonic()
        try:
            async with self.sem:
                conn = await self._connection(service)
                reasons: list[str] = []
                for route in service.pick_tools(frame):
                    outcome = await self._run_tool(conn, service, route, frame, limit)
                    if outcome is None:
                        continue
                    kind, payload = outcome
                    if kind == "skip":
                        reasons.append(payload["reason"])
                        run.missing = sorted(set(run.missing + payload["missing"]))
                        continue
                    run.tool, run.args = route.name, payload["args"]
                    run.hits = payload["hits"]
                    run.status = "ok" if run.hits else "empty"
                    run.missing = []
                    break
                else:
                    run.reason = "; ".join(dict.fromkeys(reasons)) or "no tool of this server fits the request"
        except asyncio.TimeoutError:
            run.status, run.reason = "error", "timed out"
        except Exception as e:  # noqa: BLE001 - one site down must not fail a search
            run.status, run.reason = "error", describe(e)
        run.ms = int((time.monotonic() - started) * 1000)
        return run

    async def _run_tool(self, conn: Connection, service: Service, route: ToolRoute, frame: QueryFrame, limit: int):
        schema = conn.tools.get(route.name)
        if schema is None:
            return "skip", {"reason": f"{route.name} is not offered by the installed {service.package}", "missing": []}
        absent = [s for s in route.needs if not frame.slots.get(s)]
        if absent:
            return "skip", {"reason": f"{route.name} needs {', '.join(absent)}", "missing": absent}
        if route.symbols is not None:
            low = frame.normalized.lower()
            picked = list(dict.fromkeys(slug for word, slug in route.symbols.items() if has_word(low, word)))
            args, missing = {"symbols": picked or list(route.default_symbols)}, []
            if not picked:
                note = "no particular price named: showed the main rates"
                if note not in frame.assumptions:
                    frame.assumptions.append(note)
        elif route.args is not None:
            args, missing = dict(route.args), []
        else:
            resolved: dict[str, str] = {}
            props_now = (schema or {}).get("properties") or {}

            def want(slot: str) -> str | None:
                for name, spec in props_now.items():
                    if slot_of(name) == slot and "slug" in (name + str(spec.get("description", ""))).lower():
                        return "slug"
                return None

            if service.resolve:
                for slot in ("origin", "destination", "city"):
                    if frame.slots.get(slot):
                        code = await self._resolve(conn, service, str(frame.slots[slot]), frame, want=want(slot), extra=route.resolve_args)
                        if code:
                            resolved[slot] = code
            if service.resolve_specialty and "specialty" in {slot_of(n) for n in props_now}:
                field_text = _clean_specialty(str(frame.slots.get("specialty") or (frame.slots.get("product") if "health" in frame.domain_names else "") or ""))
                if field_text:
                    code = await self._resolve(conn, service, field_text, frame, tool=service.resolve_specialty, want=want("specialty"), kind="specialty")
                    if code:
                        resolved["specialty"] = code
            coords = None
            address = ""
            props = set((schema or {}).get("properties") or {})
            if service.geocode and {p.lower() for p in props} & {"lat", "latitude", "lon", "lng", "longitude"}:
                address = str(frame.slots.get("city") or self.default_city or "")
                if address:
                    coords = await self._geocode(conn, service, address, frame)
                    if not frame.slots.get("city") and coords:
                        note = f"no place named: assumed {address}"
                        if note not in frame.assumptions:
                            frame.assumptions.append(note)
            args, missing = build_args(schema, frame, limit=limit, resolved=resolved, coords=coords, address=address)
            if missing:
                return "skip", {"reason": f"{route.name} needs {', '.join(missing)}", "missing": missing}
        result = await conn.call(route.name, args, self.tool_timeout)
        if attr(result, "isError", "is_error"):
            raise RuntimeError(result_text(result)[:300] or "the tool reported an error")
        return "ok", {"args": args, "hits": parse_hits(service.id, route.name, result, limit)}

    # -- the search -------------------------------------------------------
    async def search(
        self, frame: QueryFrame, *, limit: int = 8, max_services: int = 6,
        only: list[str] | None = None, exclude: list[str] | None = None, domains: list[str] | None = None,
        on_run: Callable[[ServiceRun], Awaitable[None] | None] | None = None,
    ) -> SearchResult:
        started = time.monotonic()
        services = self.catalog.route(frame, max_services, only=only, exclude=exclude, domains=domains)

        async def one(s: Service) -> ServiceRun:
            run = await self._run_service(s, frame, limit)
            if on_run:
                r = on_run(run)
                if asyncio.iscoroutine(r):
                    await r
            return run

        runs = list(await asyncio.gather(*(one(s) for s in services)))
        order = {"ok": 0, "empty": 1, "skipped": 2, "error": 3}
        runs.sort(key=lambda r: (order[r.status], -len(r.hits)))
        return SearchResult(frame=frame, runs=runs, ms=int((time.monotonic() - started) * 1000))


__all__ = ["Gateway", "SearchResult", "ServiceRun", "default_launcher", "pick_code", "find_coords"]
