"""Crawls a trader's CoinMarketCap community profile with a real browser.

The browser is davinci-agent's browser_automation tool (headless Chromium via
Playwright, tools/browser_automation/tool.py) run inside the evaluator, with
decifi's session mechanism (decima-davinci-flow): CoinMarketCap's community
SPA keys its login off a Bearer token in localStorage, not only cookies, so a
logged-out browser sees "This account doesn't exist" for gated profiles. The
session is a Playwright storage_state (cookies + per-origin localStorage, as
capture_cmc_session.py saves it) or a bare cookie jar (cmc_cookiejar.json, as
refresh.sh extracts it); either is auto-detected.

Session sources, first found wins: the one admins stored with the
`set_session` microtool (KV), $BROWSER_STORAGE_STATE, $BROWSER_COOKIES_FILE,
/app/cookies.json.

The profile's posts come from two places: the community ("gravity") API JSON
responses the page loads while it is scrolled — structured posts with ids,
times and coins — and, when those are missing, the rendered page text.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from typing import Any

_TEXT_KEYS = ("textContent", "text_content", "content", "text", "body", "postContent")
_TIME_KEYS = ("postTime", "createdTime", "createTime", "createdAt", "created_at", "publishTime", "time", "timestamp")
_ID_KEYS = ("gravityId", "postId", "id", "_id")
_SYMBOL = re.compile(r"(?<![A-Za-z0-9])\$([A-Za-z][A-Za-z0-9]{1,9})\b")
_STOPWORDS = {"USD", "USDT", "THE", "AND", "FOR", "NFA", "DYOR", "ATH", "ATL", "FOMO", "CEO", "ETF", "SEC", "FED", "CPI"}


def load_session(stored: Any = None) -> tuple[dict | None, list | None]:
    """(storage_state, cookies) from the stored session, else the image's files."""
    candidates: list[Any] = [stored]
    for env, default in (("BROWSER_STORAGE_STATE", ""), ("BROWSER_COOKIES_FILE", "/app/cookies.json")):
        path = (os.environ.get(env) or default).strip()
        if path and os.path.isfile(path):
            try:
                with open(path) as fh:
                    candidates.append(json.load(fh))
            except Exception:
                pass
    for value in candidates:
        if isinstance(value, str) and value.strip():
            try:
                value = json.loads(value)
            except Exception:
                continue
        if isinstance(value, dict) and ("cookies" in value or "origins" in value):
            return value, None
        if isinstance(value, list) and value:
            return None, value
    return None, None


def session_summary(stored: Any) -> dict:
    """What a stored session holds, without its secrets."""
    state, cookies = load_session(stored)
    jar = (state or {}).get("cookies") if state else cookies
    jar = jar or []
    names = {c.get("name") for c in jar if isinstance(c, dict)}
    expiries = [c.get("expires") for c in jar if isinstance(c, dict) and c.get("name") == "Authorization"]
    exp = next((e for e in expiries if isinstance(e, (int, float)) and e > 0), None)
    return {"present": bool(jar or (state or {}).get("origins")), "cookies": len(jar),
            "local_storage_origins": len((state or {}).get("origins") or []),
            "logged_in": "Authorization" in names,
            "authorization_expires": datetime.fromtimestamp(exp, timezone.utc).isoformat() if exp else None}


def _first(d: dict, keys: tuple[str, ...]) -> Any:
    for k in keys:
        v = d.get(k)
        if v not in (None, "", [], {}):
            return v
    return None


def _when(v: Any) -> str | None:
    """An ISO time from epoch seconds/ms (number or digit string) or an ISO string."""
    if v is None:
        return None
    if isinstance(v, str) and not v.strip().isdigit():
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()
        except Exception:
            return None
    try:
        n = float(v)
    except Exception:
        return None
    if n > 1e12:
        n /= 1000
    if n < 1e9:
        return None
    return datetime.fromtimestamp(n, timezone.utc).isoformat()


def symbols_in(text: str, extra: list[str] | None = None) -> list[str]:
    found = [m.upper() for m in _SYMBOL.findall(text or "")] + [s.upper() for s in (extra or []) if isinstance(s, str)]
    out: list[str] = []
    for s in found:
        if s not in _STOPWORDS and s not in out:
            out.append(s)
    return out


def _coins(post: dict) -> list[str]:
    """Coins tagged in a post: its rich content's token entries and currency lists."""
    out: list[str] = []
    rich = post.get("originalContent")
    if isinstance(rich, str):
        try:
            rich = json.loads(rich)
        except Exception:
            rich = None
    for line in rich if isinstance(rich, list) else []:
        for tok in line if isinstance(line, list) else []:
            if isinstance(tok, dict) and tok.get("type") == "token" and isinstance(tok.get("content"), dict):
                sym = tok["content"].get("symbol")
                if isinstance(sym, str):
                    out.append(sym)
    for key in ("currencies", "coins", "cryptos", "currencyList", "relatedCoins"):
        for c in post.get(key) or []:
            if isinstance(c, dict) and isinstance(c.get("symbol"), str):
                out.append(c["symbol"])
    return out


def _owner(node: dict) -> str:
    owner = node.get("owner")
    return str(owner.get("handle") or "").lower() if isinstance(owner, dict) else ""


def extract_posts(payloads: list[Any], handle: str = "") -> list[dict]:
    """The trader's own post objects in the community API responses, newest
    first (the page also loads other people's posts: pinned, suggested)."""
    posts: dict[str, dict] = {}

    def walk(node: Any, depth: int = 0) -> None:
        if depth > 12:
            return
        if isinstance(node, dict):
            text = _first(node, _TEXT_KEYS)
            when = _when(_first(node, _TIME_KEYS))
            owner = _owner(node)
            mine = not handle or not owner or owner == handle.lower()
            if isinstance(text, str) and len(text.strip()) >= 12 and when and mine:
                pid = str(_first(node, _ID_KEYS) or hash((text[:80], when)))
                images = [v for k, v in node.items() if k in ("images", "imageUrls", "pics") and isinstance(v, list)]
                posts.setdefault(pid, {
                    "id": pid, "text": text.strip()[:4000], "timestamp": when,
                    "symbols": symbols_in(text, _coins(node)),
                    "images": [i if isinstance(i, str) else (i.get("url") if isinstance(i, dict) else None)
                               for group in images for i in group][:6],
                    "likes": _first(node, ("likeCount", "likes", "reactionCount")),
                    "comments": _first(node, ("commentCount", "comments")) if not isinstance(node.get("comments"), list) else len(node["comments"]),
                    "reposts": node.get("repostCount"), "impressions": node.get("impressionCount"),
                    "topics": node.get("topics") if isinstance(node.get("topics"), list) else [],
                    "bullish": node.get("bullish"), "pinned": node.get("pinned"),
                    "edited": bool(node.get("editTime") or node.get("edited")),
                })
            for v in node.values():
                if isinstance(v, (dict, list)):
                    walk(v, depth + 1)
        elif isinstance(node, list):
            for v in node:
                walk(v, depth + 1)

    for p in payloads:
        walk(p)
    return sorted(posts.values(), key=lambda p: p["timestamp"], reverse=True)


def extract_analyst(payloads: list[Any], handle: str) -> dict:
    """The profile's own numbers (followers, posts) from the API responses."""
    out: dict[str, Any] = {"username": handle, "platform": "CoinMarketCap Community"}
    keys = {"followers": ("followers", "followerCount", "fansCount"), "following": ("following", "followingCount"),
            "total_posts": ("postCount", "posts", "totalPosts"), "nickname": ("nickname", "nickName", "displayName"),
            "avatar": ("avatarUrl", "avatar"), "bio": ("biography", "bio", "introduction")}

    def walk(node: Any, depth: int = 0) -> None:
        if depth > 10:
            return
        if isinstance(node, dict):
            if str(node.get("handle") or node.get("username") or "").lower() == handle.lower():
                for field, names in keys.items():
                    if field not in out:
                        v = _first(node, names)
                        if v is not None and not isinstance(v, (dict, list)):
                            out[field] = v
            for v in node.values():
                walk(v, depth + 1)
        elif isinstance(node, list):
            for v in node:
                walk(v, depth + 1)

    for p in payloads:
        walk(p)
    return out


def crawl(profile_url: str, handle: str, stored_session: Any = None, proxy: str = "",
          scrolls: int = 8, timeout_ms: int = 45_000) -> dict:
    """Opens the profile, scrolls through its posts and returns what it found."""
    from playwright.sync_api import sync_playwright  # the image ships it

    state, cookies = load_session(stored_session)
    payloads: list[Any] = []
    errors: list[str] = []
    page_text = ""
    final_url = profile_url
    with sync_playwright() as pw:
        args = ["--no-sandbox", "--disable-dev-shm-usage", "--disable-blink-features=AutomationControlled"]
        ignore_tls = os.environ.get("BROWSER_IGNORE_HTTPS_ERRORS", "1").strip().lower() not in ("0", "false", "no", "")
        if ignore_tls:
            args.append("--ignore-certificate-errors")
        launch: dict[str, Any] = {"headless": True, "args": args}
        proxy = (proxy or os.environ.get("BROWSER_PROXY") or "").strip()
        if proxy:
            launch["proxy"] = {"server": proxy}
        if os.environ.get("BROWSER_EXECUTABLE"):
            launch["executable_path"] = os.environ["BROWSER_EXECUTABLE"]
        browser = pw.chromium.launch(**launch)
        ctx_kwargs: dict[str, Any] = {"viewport": {"width": 1366, "height": 900},
                                      "user_agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                                     "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")}
        if ignore_tls:
            ctx_kwargs["ignore_https_errors"] = True
        if state:
            ctx_kwargs["storage_state"] = state
        context = browser.new_context(**ctx_kwargs)
        context.set_default_timeout(timeout_ms)
        if cookies:
            try:
                context.add_cookies(cookies)
            except Exception as exc:
                errors.append(f"cookies: {exc}")
        context.add_init_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
        page = context.new_page()

        def on_response(res) -> None:
            url = res.url
            if "coinmarketcap" not in url or ("gravity" not in url and "community" not in url):
                return
            if "json" not in (res.headers.get("content-type") or ""):
                return
            try:
                payloads.append(res.json())
            except Exception:
                pass

        page.on("response", on_response)
        try:
            page.goto(profile_url, wait_until="domcontentloaded", timeout=timeout_ms)
            try:
                page.wait_for_load_state("networkidle", timeout=15_000)
            except Exception:
                pass
            idle = 0
            for _ in range(scrolls):
                before = len(payloads)
                page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                page.wait_for_timeout(1800)
                idle = idle + 1 if len(payloads) == before else 0
                if idle >= 3:  # nothing more loads: the end of the profile
                    break
            final_url = page.url
            page_text = (page.evaluate("document.body.innerText") or "")[:60_000]
        except Exception as exc:
            errors.append(f"navigation: {exc}")
        finally:
            context.close()
            browser.close()

    posts = extract_posts(payloads, handle)
    missing = "doesn't exist" in page_text.lower() or "does not exist" in page_text.lower()
    return {"url": final_url, "analyst": extract_analyst(payloads, handle), "posts": posts,
            "page_text": page_text if not posts else page_text[:8000],
            "logged_out_or_missing": missing and not posts, "errors": errors,
            "api_responses": len(payloads)}
