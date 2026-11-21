"""Google Maps, through the Google Maps Scraper Kit's local engine.

The kit (https://github.com/Mahanaicoach/google-maps-scraper-kit, AGPL-3.0) is
not a library and not an MCP server: it is a local HTTP engine (engine/serve.py)
that drives a headless Chrome against Google Maps, with a job API:

    POST   /api/v1/jobs                      {"name", "keywords", "lang", "max_time", ...} → {"id"}
    GET    /api/v1/jobs/<id>                 Status: pending | working | ok | failed
    GET    /api/v1/jobs/<id>/download?format=json   the rows so far, while it works
    DELETE /api/v1/jobs/<id>

Peyda runs it unmodified, as its own process (installed by scripts/install.sh at
a pinned commit), and talks to it only over this API. `Engine` is that client;
`peyda/gmaps_mcp.py` puts it behind an MCP tool so the gateway asks Google Maps
the way it asks every iran-mcp server, in plain search and in the agentic loop.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

# The kit's code Peyda installs: a commit, not a branch, so an update upstream changes nothing here.
KIT_REPO = "Mahanaicoach/google-maps-scraper-kit"
KIT_COMMIT = "c3e63f1934dc61e9b9ae52b56de6f0beceb0a703"  # engine 2.5.1, 2026-11-19
DEFAULT_KIT_DIR = "/workspace/.gmaps-kit"
DEFAULT_PORT = 8765  # not 8080 (the kit's default), which a project's app may well use

_PERSIAN = re.compile(r"[؀-ۿ]")


class EngineError(RuntimeError):
    pass


def settings(env: dict[str, str] | None = None) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    port = int(env.get("PEYDA_GMAPS_PORT") or DEFAULT_PORT)
    return {
        "kit_dir": env.get("PEYDA_GMAPS_KIT") or DEFAULT_KIT_DIR,
        "base_url": (env.get("PEYDA_GMAPS_URL") or f"http://127.0.0.1:{port}").rstrip("/"),
        "port": port,
        "api_key": env.get("PEYDA_GMAPS_API_KEY", ""),
        # Google Maps does not need the Iranian proxy; a proxy of its own when the computer needs one.
        "proxy": env.get("PEYDA_GMAPS_PROXY", ""),
        "country": (env.get("PEYDA_GMAPS_COUNTRY") or "ir").lower(),
        "default_city": env.get("PEYDA_DEFAULT_CITY", "تهران"),
        "max_seconds": int(env.get("PEYDA_GMAPS_MAX_SECONDS") or 40),
        "python": env.get("PEYDA_GMAPS_PYTHON") or "python3",
    }


class Engine:
    """A client for one engine. Requests to it never go through a proxy: it
    listens on this computer only, and a computer's HTTP(S)_PROXY would refuse
    or misroute 127.0.0.1."""

    def __init__(self, base_url: str, *, kit_dir: str = "", port: int = DEFAULT_PORT, api_key: str = "",
                 proxy: str = "", country: str = "ir", python: str = "python3") -> None:
        self.base_url = base_url.rstrip("/")
        self.kit_dir = kit_dir
        self.port = port
        self.api_key = api_key
        self.proxy = proxy
        self.country = country
        self.python = python
        self._open = urllib.request.build_opener(urllib.request.ProxyHandler({})).open

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Engine":
        s = settings(env)
        return cls(s["base_url"], kit_dir=s["kit_dir"], port=s["port"], api_key=s["api_key"],
                   proxy=s["proxy"], country=s["country"], python=s["python"])

    # -- HTTP -------------------------------------------------------------
    def _request(self, method: str, path: str, body: Any = None, timeout: float = 15) -> tuple[int, Any]:
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        req = urllib.request.Request(self.base_url + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.api_key:
            req.add_header("X-API-Key", self.api_key)
        try:
            with self._open(req, timeout=timeout) as r:
                raw = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            raw, status = e.read(), e.code
        try:
            return status, json.loads(raw or b"null")
        except ValueError:
            return status, raw.decode("utf-8", "replace")

    def alive(self) -> bool:
        try:
            status, _ = self._request("GET", "/api/v1/jobs", timeout=3)
            return status == 200
        except OSError:
            return False

    # -- starting ---------------------------------------------------------
    def ensure(self, wait: float = 90) -> None:
        """The engine is answering, or EngineError. Starts it with the kit's own
        `scripts/engine.py start` (it detaches, keeps its log in the kit's .engine/
        folder, and finds the Chrome the install downloaded)."""
        if self.alive():
            return
        script = Path(self.kit_dir) / "scripts" / "engine.py"
        if not script.is_file():
            raise EngineError(f"the Google Maps engine is not installed (no {script}); rerun the install")
        env = dict(os.environ, SCRAPER_PORT=str(self.port), SCRAPER_NO_UPDATE_CHECK="1")
        if self.api_key:
            env["SCRAPER_API_KEY"] = self.api_key
        try:
            out = subprocess.run([self.python, str(script), "start"], cwd=self.kit_dir, env=env,
                                 capture_output=True, text=True, timeout=wait, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            out = None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.alive():
                return
            time.sleep(0.5)
        said = (out.stdout + out.stderr).strip()[-300:] if out else f"engine.py start took over {wait:.0f}s"
        raise EngineError(f"the Google Maps engine did not start: {said or 'no output'}")

    # -- a search ---------------------------------------------------------
    def search(self, keyword: str, *, lang: str = "", lat: float | None = None, lon: float | None = None,
               depth: int = 1, max_seconds: int = 40, poll: float = 1.0) -> list[dict[str, str]]:
        """The places Google Maps lists for `keyword`, as the engine's rows. At the
        deadline the rows found so far are returned and the job is dropped, so a
        slow search costs at most `max_seconds`."""
        self.ensure()
        lang = lang or ("fa" if _PERSIAN.search(keyword) else "en")
        job: dict[str, Any] = {
            "name": "peyda", "keywords": [keyword], "lang": lang, "depth": max(1, min(depth, 6)),
            # the engine's own clock is the hard stop; ours (below) is a few seconds longer
            "max_time": max(10, int(max_seconds)), "email": False, "socials": False, "reviews_max": 0,
        }
        if self.country:
            job["country"] = self.country
        if lat is not None and lon is not None:
            job["lat"], job["lon"] = f"{lat:.6f}", f"{lon:.6f}"
        if self.proxy:
            job["proxies"] = [self.proxy]
        status, made = self._request("POST", "/api/v1/jobs", job)
        if status != 201 or not isinstance(made, dict) or not made.get("id"):
            raise EngineError(f"the engine refused the search ({status}): {_message(made)}")
        jid = urllib.parse.quote(str(made["id"]), safe="")
        deadline = time.monotonic() + max_seconds + 5
        state: dict[str, Any] = {}
        try:
            while time.monotonic() < deadline:
                status, got = self._request("GET", f"/api/v1/jobs/{jid}")
                if status == 200 and isinstance(got, dict):
                    state = got
                    if state.get("Status") in ("ok", "failed"):
                        break
                time.sleep(poll)
            status, rows = self._request("GET", f"/api/v1/jobs/{jid}/download?format=json", timeout=30)
            rows = rows if status == 200 and isinstance(rows, list) else []
        finally:
            try:
                self._request("DELETE", f"/api/v1/jobs/{jid}", timeout=5)
            except OSError:
                pass
        if not rows and state.get("Status") == "failed":
            raise EngineError(f"Google Maps search failed: {str(state.get('Error') or 'no reason given')[:240]}")
        return [r for r in rows if isinstance(r, dict)]


def _message(data: Any) -> str:
    if isinstance(data, dict):
        return str(data.get("message") or data.get("error") or data)[:200]
    return str(data)[:200]


def _num(v: Any) -> float | None:
    try:
        f = float(str(v).replace(",", "").strip())
    except (TypeError, ValueError):
        return None
    return f if f == f else None


def place(row: dict[str, str]) -> dict[str, Any]:
    """One engine row (36 columns, every value a string) → the compact record the
    gateway reads: `title`, `url`, `subtitle` (category), `description`
    (rating, reviews, phone), `address`, `image`, and the raw facts beside them."""
    rating = _num(row.get("review_rating"))
    reviews = _num(row.get("review_count"))
    phone = (row.get("phone") or "").strip()
    website = (row.get("website") or "").strip()
    bits = []
    if rating:
        bits.append(f"★ {rating:g}" + (f" ({int(reviews):,})" if reviews else ""))
    if phone:
        bits.append(phone)
    if (row.get("status") or "").strip():
        bits.append(row["status"].strip())
    out: dict[str, Any] = {
        "title": (row.get("title") or "").strip(),
        "url": (row.get("link") or "").strip(),
        "subtitle": (row.get("category") or "").strip(),
        "description": " · ".join(bits),
        "address": (row.get("address") or row.get("complete_address") or "").strip(),
        "image": (row.get("thumbnail") or "").strip(),
        "phone": phone, "website": website,
        "rating": rating, "reviews": int(reviews) if reviews else None,
        "lat": _num(row.get("latitude")), "lon": _num(row.get("longitude")),
        "place_id": (row.get("place_id") or "").strip(),
    }
    return {k: v for k, v in out.items() if v not in ("", None)}


def keyword_for(query: str, city: str = "") -> str:
    """What Google Maps is asked: the query, with the city when the query does not name it."""
    q = " ".join(str(query or "").split())
    c = " ".join(str(city or "").split())
    if c and c.lower() not in q.lower():
        q = f"{q} {c}" if q else c
    return q


__all__ = ["Engine", "EngineError", "KIT_COMMIT", "KIT_REPO", "keyword_for", "place", "settings"]
