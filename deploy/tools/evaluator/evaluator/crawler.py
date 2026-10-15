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


# Where a post object keeps its media, its link preview, the post it quotes or
# reposts, and its poll (CoinMarketCap's gravity API names vary by version).
_MEDIA_KEYS = ("images", "imageUrls", "imageList", "pics", "pictures", "photos", "medias", "mediaList",
               "media", "attachments", "videos", "video", "videoUrl", "videoList", "gifs", "gif")
_URL_KEYS = ("url", "originalUrl", "originUrl", "src", "imageUrl", "imgUrl", "videoUrl", "playUrl", "fileUrl", "link")
_LINK_KEYS = ("linkCard", "linkPreview", "card", "urlPreview", "linkInfo")
_QUOTE_KEYS = ("repostOriginal", "originalPost", "originPost", "quotedPost", "quotePost", "repost",
               "sharedPost", "referencedPost", "originalGravity", "forwardPost")
_POLL_KEYS = ("poll", "vote", "voteInfo", "pollInfo")
_VIDEO_EXT = (".mp4", ".mov", ".webm", ".m3u8", ".m4v")
MAX_MEDIA = 9


def _media_kind(url: str, hint: str = "") -> str:
    low = (hint + " " + url.split("?")[0]).lower()
    if "video" in low or low.endswith(_VIDEO_EXT):
        return "video"
    if "gif" in low:
        return "gif"
    return "image"


def _media_in(value: Any, hint: str = "") -> list[dict]:
    """Media {url, kind} in one media field: a URL, an object with one, or a list of either."""
    out: list[dict] = []
    if isinstance(value, str):
        if value.startswith(("https://", "http://")):
            out.append({"url": value, "kind": _media_kind(value, hint)})
    elif isinstance(value, dict):
        kind = str(value.get("type") or value.get("mediaType") or value.get("mime") or hint)
        for k in _URL_KEYS:
            url = value.get(k)
            if isinstance(url, str) and url.startswith(("https://", "http://")):
                out.append({"url": url, "kind": _media_kind(url, kind + " " + k)})
                break
    elif isinstance(value, list):
        for v in value:
            out.extend(_media_in(v, hint))
    return out


def _rich(node: dict) -> list:
    rich = node.get("originalContent") or node.get("richContent")
    if isinstance(rich, str):
        try:
            rich = json.loads(rich)
        except Exception:
            return []
    return rich if isinstance(rich, list) else []


def rich_text(node: dict, fallback: str) -> str:
    """The post's text from its rich content, keeping what plain text loses:
    links' URLs, mentions, hashtags and coins; else [fallback]."""
    lines: list[str] = []
    for line in _rich(node):
        parts: list[str] = []
        for tok in line if isinstance(line, list) else [line]:
            if isinstance(tok, str):
                parts.append(tok)
                continue
            if not isinstance(tok, dict):
                continue
            kind, content = str(tok.get("type") or ""), tok.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, dict):
                text = str(content.get("text") or content.get("name") or content.get("handle")
                           or content.get("symbol") or content.get("url") or "")
            else:
                text = ""
            url = tok.get("url") or tok.get("link") or (content.get("url") if isinstance(content, dict) else None)
            if kind == "token" and isinstance(content, dict) and content.get("symbol"):
                text = "$" + str(content["symbol"]).lstrip("$")
            elif kind in ("mention", "user", "at") and text and not text.startswith("@"):
                text = "@" + text
            elif kind in ("hashtag", "topic", "tag") and text and not text.startswith("#"):
                text = "#" + text
            elif kind in ("link", "url") and isinstance(url, str) and url not in text:
                text = f"{text} ({url})" if text else url
            elif kind in ("image", "video", "gif"):
                text = ""  # carried as media
            parts.append(text)
        lines.append("".join(parts))
    text = "\n".join(lines).strip()
    return text if len(text) >= len((fallback or "").strip()) * 0.8 else (fallback or "").strip()


def post_media(node: dict) -> list[dict]:
    """Every image, GIF and video of a post, in order, at most MAX_MEDIA."""
    found: list[dict] = []
    for k in _MEDIA_KEYS:
        if k in node:
            found.extend(_media_in(node[k], k))
    for line in _rich(node):
        for tok in line if isinstance(line, list) else []:
            if isinstance(tok, dict) and str(tok.get("type") or "") in ("image", "video", "gif"):
                found.extend(_media_in(tok.get("content") if tok.get("content") is not None else tok, str(tok["type"])))
                found.extend(_media_in(tok.get("url"), str(tok["type"])))
    out, seen = [], set()
    for m in found:
        if m["url"] not in seen:
            seen.add(m["url"])
            out.append(m)
    return out[:MAX_MEDIA]


def post_link(node: dict) -> dict | None:
    for k in _LINK_KEYS:
        card = node.get(k)
        if isinstance(card, dict):
            url = card.get("url") or card.get("link")
            if isinstance(url, str) and url.startswith(("https://", "http://")):
                return {"url": url, "title": str(card.get("title") or "").strip()[:200],
                        "description": str(card.get("description") or card.get("desc") or "").strip()[:300]}
    return None


def post_quote(node: dict) -> dict | None:
    """The post this one quotes or reposts: its author, text and media."""
    for k in _QUOTE_KEYS:
        q = node.get(k)
        if isinstance(q, dict):
            text = _first(q, _TEXT_KEYS)
            if isinstance(text, str) and text.strip():
                return {"author": _owner(q), "id": str(_first(q, _ID_KEYS) or ""),
                        "text": rich_text(q, text)[:1500], "media": post_media(q)}
    return None


def post_poll(node: dict) -> list[str]:
    for k in _POLL_KEYS:
        poll = node.get(k)
        opts = poll.get("options") or poll.get("items") or poll.get("choices") if isinstance(poll, dict) else None
        if isinstance(opts, list):
            out = []
            for o in opts:
                label = o if isinstance(o, str) else (o.get("text") or o.get("content") or o.get("name") or o.get("option")
                                                      if isinstance(o, dict) else None)
                if isinstance(label, str) and label.strip():
                    out.append(label.strip())
            if out:
                return out[:10]
    return []


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
                media = post_media(node)
                posts.setdefault(pid, {
                    "id": pid, "text": text.strip()[:4000], "timestamp": when,
                    "rich_text": rich_text(node, text)[:4000],
                    "symbols": symbols_in(text, _coins(node)),
                    "media": media,
                    "images": [m["url"] for m in media if m["kind"] != "video"][:6],
                    "link": post_link(node), "quote": post_quote(node), "poll": post_poll(node),
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
