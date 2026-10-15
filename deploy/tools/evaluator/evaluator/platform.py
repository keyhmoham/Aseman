"""Each trader's own account on this Tradera platform.

When a trader is added the evaluator makes them an ordinary user account
(users.account_create through the tool gateway — allowed only in the platform
admins space, for an administrator): the trader's CoinMarketCap handle, or a
username an admin picks, and a random password the evaluator keeps (admins
read it with `trader_credentials`).

Every evaluation round the evaluator publishes the trader's latest posts, the
ones the evaluation read, through the tool gateway's posts.post_import (as the
account it made, from the platform admins space): each CoinMarketCap post is
published once, as a global post, and never edited or replaced afterwards;
the node features each trader's 10 latest imported posts at the top of the
global feed. To remove a trader's posts the evaluator signs in as them through
the node's public API, exactly as the app does — auth.login, then every
request signed with the account's Ed25519 key (method, path, nonce, timestamp
and the body's sha256).
"""

from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import os
import re
import secrets
import string
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from typing import Any

POSTS_PER_ROUND = 10
# How many published posts a trader's record remembers (to update or remove).
REMEMBERED_POSTS = 60
_HANDLE_OK = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{1,28}[a-z0-9])$")


class PlatformError(Exception):
    def __init__(self, message: str, status: int = 0, code: str = ""):
        super().__init__(message)
        self.status, self.code = status, code


def username_for(raw: str) -> str:
    """A valid platform username (3-30 of a-z 0-9 . _ -, letter or digit at
    both ends) from a CoinMarketCap handle or an admin's choice."""
    h = re.sub(r"[^a-z0-9._-]", "_", (raw or "").strip().lstrip("@").lower())
    h = h.strip("._-")[:30].rstrip("._-")
    if len(h) < 3:
        h = (h + "_trader").strip("._-")[:30]
    return h


def valid_username(h: str) -> bool:
    return bool(_HANDLE_OK.match(h or ""))


def new_password() -> str:
    """A random 20-character password (letters, digits and a few symbols)."""
    alphabet = string.ascii_letters + string.digits + "-_.!@"
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(20))
        if any(c.isdigit() for c in pw) and any(c.isupper() for c in pw) and any(c.islower() for c in pw):
            return pw


def sign_headers(private_key_hex: str, method: str, path: str, body: bytes) -> dict[str, str]:
    """The node's request signature: Ed25519 over
    method\\npath\\nnonce\\ntimestamp\\nsha256(body), hex encoded."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    nonce = secrets.token_hex(16)
    ts = str(int(time.time()))
    payload = "\n".join([method, path, nonce, ts, hashlib.sha256(body).hexdigest()]).encode()
    key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(private_key_hex)[:32])
    return {"X-Tradera-Nonce": nonce, "X-Tradera-Timestamp": ts, "X-Tradera-Signature": key.sign(payload).hex()}


@dataclass
class Session:
    account_id: str
    handle: str
    token: str
    private_key: str


class Platform:
    """The node's public API (/v1/{namespace}/{action}), as a signed-in person."""

    def __init__(self, url: str | None = None, timeout: float = 60.0):
        self.url = (url or os.environ.get("TRADERA_NODE_URL") or "http://tradera:8080").rstrip("/")
        self.timeout = timeout

    def _post(self, namespace: str, action: str, body: dict, session: Session | None = None) -> dict:
        path = f"/v1/{namespace}/{action}"
        raw = json.dumps(body).encode()
        headers = {"Content-Type": "application/json"}
        if session is not None:
            headers["Authorization"] = f"Bearer {session.token}"
            headers.update(sign_headers(session.private_key, "POST", path, raw))
        req = urllib.request.Request(self.url + path, data=raw, method="POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as res:
                out = res.read()
        except urllib.error.HTTPError as e:
            try:
                err = json.loads(e.read() or b"{}")
            except Exception:
                err = {}
            raise PlatformError(str(err.get("error") or f"{namespace}.{action}: HTTP {e.code}"),
                                status=e.code, code=str(err.get("code") or "")) from None
        except urllib.error.URLError as e:
            raise PlatformError(f"node unreachable: {e.reason}") from None
        return json.loads(out) if out.strip() else {}

    def login(self, handle: str, password: str) -> Session:
        out = self._post("auth", "login", {"account": handle, "password": password})
        if not out.get("token") or not out.get("private_key"):
            raise PlatformError("login returned no session")
        return Session(out.get("account_id", ""), out.get("handle", handle), out["token"], out["private_key"])

    def logout(self, session: Session) -> None:
        try:
            self._post("auth", "logout", {}, session)
        except PlatformError:
            pass

    def call(self, session: Session, namespace: str, action: str, body: dict) -> dict:
        return self._post(namespace, action, body, session)


# The node's limit on a post's body.
MAX_BODY = 4000
# A medium larger than this is linked in the post instead of attached.
MAX_MEDIA_BYTES = {"image": 8 << 20, "gif": 12 << 20, "video": 24 << 20}
_MEDIA_TYPES = ("image/", "video/")


def post_body(post: dict, unattached: list[str] | None = None) -> str:
    """A CoinMarketCap post as published on the platform: all of its text
    (with its links, mentions, hashtags and coins), its poll, its link
    preview, the post it quotes, links to any media that could not be
    attached, and where it was posted."""
    text = (post.get("rich_text") or post.get("text") or "").strip()
    extra: list[str] = []
    poll = [o for o in (post.get("poll") or []) if isinstance(o, str) and o.strip()]
    if poll:
        extra.append("Poll:\n" + "\n".join(f"• {o}" for o in poll))
    card = post.get("link") or {}
    if card.get("url") and card["url"] not in text:
        extra.append("\n".join(x for x in ("🔗 " + (card.get("title") or card["url"]), card.get("description") or "",
                                            card["url"] if card.get("title") else "") if x))
    quote = post.get("quote") or {}
    if (quote.get("text") or "").strip():
        who = f"@{quote['author']}" if quote.get("author") else "a post"
        quoted = "\n".join("> " + line for line in quote["text"].strip().splitlines())
        qlink = f"\n> https://coinmarketcap.com/community/post/{quote['id']}/" if str(quote.get("id", "")).isdigit() else ""
        qmedia = "".join(f"\n> {m['url']}" for m in quote.get("media") or [] if m.get("url"))
        extra.append(f"Quoting {who}:\n{quoted}{qmedia}{qlink}")
    if unattached:
        extra.append("Media:\n" + "\n".join(unattached))
    when = post.get("timestamp") or ""
    try:
        when = datetime.fromisoformat(when).strftime("%d %b %Y %H:%M UTC")
    except Exception:
        pass
    link = f"https://coinmarketcap.com/community/post/{post['id']}/" if str(post.get("id", "")).isdigit() else ""
    tail = f"— Posted on CoinMarketCap · {when}" + (f"\n{link}" if link else "")
    rest = "\n\n".join(extra + [tail])
    room = MAX_BODY - len(rest) - 2
    if len(text) > room:
        text = text[:max(0, room - 1)].rstrip() + "…"
    return f"{text}\n\n{rest}".strip()[:MAX_BODY]


def fetch_media(url: str, kind: str, proxy: str = "", timeout: float = 60.0) -> dict | None:
    """One medium as a posts.post_import attachment {name, mime, data
    (base64)}, or None when it cannot be downloaded or is too large."""
    limit = MAX_MEDIA_BYTES.get(kind, MAX_MEDIA_BYTES["image"])
    handlers = [urllib.request.ProxyHandler({"http": proxy, "https": proxy})] if proxy else []
    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; TraderaEvaluator/1.0)",
                                               "Referer": "https://coinmarketcap.com/"})
    try:
        with opener.open(req, timeout=timeout) as res:
            mime = (res.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            data = res.read(limit + 1)
    except Exception:
        return None
    if not data or len(data) > limit:
        return None
    if not mime.startswith(_MEDIA_TYPES):
        guess = mimetypes.guess_type(url.split("?")[0])[0] or ""
        if not guess.startswith(_MEDIA_TYPES):
            return None
        mime = guess
    name = os.path.basename(url.split("?")[0].rstrip("/")) or "media"
    if "." not in name:
        name += mimetypes.guess_extension(mime) or ""
    return {"name": name[:120], "mime": mime, "data": base64.b64encode(data).decode()}


def post_tags(post: dict) -> list[str]:
    return [s.lower() for s in (post.get("symbols") or [])[:4]] + ["coinmarketcap"]


SOURCE = "coinmarketcap"


def newest(posts: list[dict], limit: int = POSTS_PER_ROUND) -> list[dict]:
    """The newest [limit] posts that can be published."""
    out = sorted(posts, key=lambda p: p.get("timestamp") or "", reverse=True)[:limit]
    return [p for p in out if str(p.get("id") or "") and (p.get("text") or "").strip()]


def import_item(post: dict, fetch=None) -> dict:
    """A post as a posts.post_import item, with its media attached ([fetch]
    downloads one: url, kind -> attachment or None; without it, media are
    linked in the body)."""
    media, unattached = [], []
    for m in post.get("media") or []:
        got = fetch(m["url"], m.get("kind") or "image") if fetch else None
        if got:
            media.append(got)
        else:
            unattached.append(m["url"])
    return {"source": SOURCE, "source_id": str(post["id"]), "body": post_body(post, unattached),
            "tags": post_tags(post), "at": post.get("timestamp") or "", "media": media}


def remember(published: dict[str, Any], items: list[dict], results: list[dict]) -> dict[str, Any]:
    """[published] (a CoinMarketCap post id -> {post_id, at}: what the
    evaluator published as the trader, to delete with them) with an import's
    results added, keeping the newest REMEMBERED_POSTS."""
    published = dict(published or {})
    at = {i["source_id"]: i.get("at") for i in items}
    for r in results or []:
        if r.get("post_id") and r.get("source_id"):
            published[r["source_id"]] = {"post_id": r["post_id"], "at": at.get(r["source_id"])}
    if len(published) > REMEMBERED_POSTS:
        keep = sorted(published.items(), key=lambda kv: kv[1].get("at") or "", reverse=True)[:REMEMBERED_POSTS]
        published = dict(keep)
    return published


def delete_posts(platform: Platform, session: Session, published: dict[str, Any]) -> int:
    """Deletes what the evaluator published as the trader; returns how many."""
    gone = 0
    for item in (published or {}).values():
        post_id = (item or {}).get("post_id")
        if not post_id:
            continue
        try:
            platform.call(session, "posts", "post_delete", {"post": post_id})
            gone += 1
        except PlatformError as e:
            if e.status == 404 or e.code == "NOT_FOUND":
                gone += 1
    return gone
