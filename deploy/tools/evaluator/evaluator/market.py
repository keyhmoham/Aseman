"""Verifiable market data for a trader's posts.

The prompt demands that "every score must be generated from verifiable market
data". For every coin the posts name, the evaluator fetches daily OHLCV from
Binance's public market-data API (no key; data-api.binance.vision first, as it
is reachable where api.binance.com is geo-blocked) and measures what the price
actually did after each post: forward returns over 1/3/7/30 days and the
maximum favorable / adverse excursion over the next 7 days, both ways. The
Crypto Fear & Greed index (alternative.me) at the time of each post is added.
The model judges direction, targets and timing against these numbers.
"""

from __future__ import annotations

import json
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

BINANCE_HOSTS = ("https://data-api.binance.vision", "https://api.binance.com")
FNG_URL = "https://api.alternative.me/fng/?limit=0&format=json"
DAY = 86_400_000

Fetch = Callable[[str], Any]


def http_json(url: str, timeout: float = 20.0) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": "tradera-evaluator/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as res:
        return json.loads(res.read())


def klines(symbol: str, start_ms: int, fetch: Fetch = http_json) -> list[list[float]]:
    """Daily [open_time, open, high, low, close, volume] of SYMBOLUSDT from start."""
    for host in BINANCE_HOSTS:
        out: list[list[float]] = []
        cursor = start_ms
        try:
            for _ in range(6):  # up to ~16 years of days
                rows = fetch(f"{host}/api/v3/klines?symbol={symbol}USDT&interval=1d&startTime={cursor}&limit=1000")
                if not isinstance(rows, list) or not rows:
                    break
                out += [[float(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5])] for r in rows]
                if len(rows) < 1000:
                    break
                cursor = int(rows[-1][0]) + DAY
            return out
        except Exception:
            continue
    return []


def fear_greed(fetch: Fetch = http_json) -> dict[str, dict]:
    """Day (YYYY-MM-DD) -> {value, classification}."""
    try:
        data = fetch(FNG_URL).get("data") or []
    except Exception:
        return {}
    out = {}
    for row in data:
        try:
            day = datetime.fromtimestamp(int(row["timestamp"]), timezone.utc).strftime("%Y-%m-%d")
            out[day] = {"value": int(row["value"]), "classification": row.get("value_classification")}
        except Exception:
            continue
    return out


def _pct(a: float, b: float) -> float:
    return round((b - a) / a * 100, 2) if a else 0.0


def outcome(series: list[list[float]], at: datetime) -> dict | None:
    """What the price did after a post made at `at`."""
    t = at.timestamp() * 1000
    i = next((k for k, row in enumerate(series) if row[0] <= t < row[0] + DAY), None)
    if i is None:
        return None
    entry = series[i][4] if t >= series[i][0] + DAY / 2 else series[i][1]
    out: dict[str, Any] = {"price_at_post": entry}
    for days in (1, 3, 7, 30):
        if i + days < len(series):
            out[f"return_{days}d_pct"] = _pct(entry, series[i + days][4])
    window = series[i + 1:i + 8]
    if window:
        hi, lo = max(r[2] for r in window), min(r[3] for r in window)
        out["max_up_7d_pct"] = _pct(entry, hi)      # long MFE / short MAE
        out["max_down_7d_pct"] = _pct(entry, lo)    # long MAE / short MFE
        closes = [r[4] for r in series[max(0, i - 14):i + 1]]
        trs = [r[2] - r[3] for r in series[max(0, i - 14):i + 1]]
        out["atr14_pct_at_post"] = round(sum(trs) / len(trs) / entry * 100, 2) if trs and entry else None
        out["trend_14d_pct_before_post"] = _pct(closes[0], closes[-1]) if len(closes) > 1 else None
    out["evaluation_window_complete_7d"] = i + 7 < len(series)
    return out


def market_context(posts: list[dict], fetch: Fetch = http_json, max_symbols: int = 10) -> dict:
    """Per-post outcomes and per-coin summaries for the posts' coins."""
    counts: dict[str, int] = {}
    for p in posts:
        for s in p.get("symbols") or []:
            counts[s] = counts.get(s, 0) + 1
    symbols = sorted(counts, key=lambda s: -counts[s])[:max_symbols]
    times = [datetime.fromisoformat(p["timestamp"]) for p in posts if p.get("timestamp")]
    if not symbols or not times:
        return {"source": "binance daily klines", "symbols": {}, "posts": {}, "note": "no coin symbols found in the posts"}
    start = int((min(times) - timedelta(days=20)).timestamp() * 1000)
    series = {s: klines(s, start, fetch) for s in symbols}
    fng = fear_greed(fetch)
    per_post: dict[str, Any] = {}
    for p in posts:
        at = datetime.fromisoformat(p["timestamp"]) if p.get("timestamp") else None
        if at is None:
            continue
        row: dict[str, Any] = {}
        for s in p.get("symbols") or []:
            if series.get(s):
                o = outcome(series[s], at)
                if o:
                    row[s] = o
        mood = fng.get(at.strftime("%Y-%m-%d"))
        if mood:
            row["fear_greed_at_post"] = mood
        if row:
            per_post[p["id"]] = row
    summary = {}
    for s, rows in series.items():
        if rows:
            summary[s] = {"days": len(rows), "first_close": rows[0][4], "last_close": rows[-1][4],
                          "change_pct_over_period": _pct(rows[0][4], rows[-1][4]),
                          "period": [datetime.fromtimestamp(rows[0][0] / 1000, timezone.utc).date().isoformat(),
                                     datetime.fromtimestamp(rows[-1][0] / 1000, timezone.utc).date().isoformat()]}
        else:
            summary[s] = {"unavailable": "no USDT market on Binance"}
    return {"source": "binance daily klines (USDT pairs); alternative.me fear & greed",
            "symbols": summary, "posts": per_post}
