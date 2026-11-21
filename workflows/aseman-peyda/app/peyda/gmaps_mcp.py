"""Google Maps as an MCP server over stdio, in front of the Google Maps Scraper
Kit's local engine (see peyda/gmaps.py).

The gateway launches it like an iran-mcp server (`python -m peyda.gmaps_mcp`)
and reads its tools' schemas the same way, so Google Maps answers in plain
search and in the agentic loop with no special case. Any other MCP client
(Claude Code, an agent) can use it too:

    claude mcp add peyda-gmaps -- /workspace/.venvs/peyda/bin/python -m peyda.gmaps_mcp

Settings come from the environment: PEYDA_GMAPS_KIT, PEYDA_GMAPS_PORT (or
PEYDA_GMAPS_URL), PEYDA_GMAPS_PROXY, PEYDA_GMAPS_COUNTRY, PEYDA_GMAPS_MAX_SECONDS,
PEYDA_DEFAULT_CITY.
"""
from __future__ import annotations

import asyncio
import json
import threading
import time
from typing import Any

try:  # MCP SDK 2.x renamed FastMCP
    from mcp.server.mcpserver import MCPServer as FastMCP
except ImportError:  # MCP SDK 1.x
    from mcp.server.fastmcp import FastMCP

from peyda.gmaps import Engine, EngineError, keyword_for, place, settings

mcp = FastMCP("peyda-gmaps")

_S = settings()
_engine = Engine.from_env()
_lock = threading.Lock()  # the engine runs one job at a time; so do we
_cache: dict[tuple[Any, ...], tuple[float, list[dict[str, Any]]]] = {}
CACHE_SECONDS = 600


def _search(keyword: str, lat: float | None, lon: float | None, depth: int) -> list[dict[str, Any]]:
    key = (keyword.lower(), lat, lon, depth)
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    with _lock:
        rows = _engine.search(keyword, lat=lat, lon=lon, depth=depth, max_seconds=_S["max_seconds"])
    places = [p for p in (place(r) for r in rows) if p.get("title")]
    _cache[key] = (time.monotonic(), places)
    for k in [k for k, (t, _) in _cache.items() if time.monotonic() - t > CACHE_SECONDS]:
        _cache.pop(k, None)
    return places


@mcp.tool()
async def gm_search(query: str, city: str = "", limit: int = 8, lat: float | None = None, lon: float | None = None) -> str:
    """Search Google Maps for places and local businesses (cafés, restaurants,
    shops, clinics, hotels, workshops...). Returns each place's name, category,
    address, phone, website, rating and review count, coordinates and its Google
    Maps link. `city` is added to the query when the query does not name it; with
    neither a city nor coordinates the default city is assumed. Takes 10-40 s."""
    assumed = ""
    if not city and (lat is None or lon is None) and _S["default_city"] and _S["default_city"] not in query:
        city, assumed = _S["default_city"], _S["default_city"]
    keyword = keyword_for(query, city)
    if not keyword:
        raise ValueError("query is empty")
    try:
        places = await asyncio.to_thread(_search, keyword, lat, lon, 1)
    except EngineError as e:
        raise RuntimeError(str(e)) from e
    out: dict[str, Any] = {"query": keyword, "source": "Google Maps", "places": places[:max(1, min(limit, 20))]}
    if assumed:
        out["assumed_city"] = assumed
    return json.dumps(out, ensure_ascii=False)


@mcp.tool()
async def gm_status() -> str:
    """Whether the Google Maps engine is installed and answering."""
    alive = await asyncio.to_thread(_engine.alive)
    return json.dumps({"engine": _engine.base_url, "running": alive, "kit": _S["kit_dir"]})


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
