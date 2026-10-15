"""Each trader's own account on this Tradera platform.

When a trader is added the evaluator makes them an ordinary user account
(users.account_create through the tool gateway — allowed only in the platform
admins space, for an administrator): the trader's CoinMarketCap handle, or a
username an admin picks, and a random password the evaluator keeps (admins
read it with `trader_credentials`).

Every evaluation round the evaluator signs in as the trader through the node's
public API, exactly as the app does — auth.login, then every request signed
with the account's Ed25519 key (method, path, nonce, timestamp and the body's
sha256) — and upserts the trader's latest posts, the ones the evaluation read:
missing ones are published, changed ones are replaced, and one deleted on the
platform is published again.
"""

from __future__ import annotations

import hashlib
import json
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


def post_body(post: dict) -> str:
    """A CoinMarketCap post as published on the platform."""
    text = (post.get("text") or "").strip()
    when = post.get("timestamp") or ""
    try:
        when = datetime.fromisoformat(when).strftime("%d %b %Y %H:%M UTC")
    except Exception:
        pass
    link = f"https://coinmarketcap.com/community/post/{post['id']}/" if str(post.get("id", "")).isdigit() else ""
    tail = f"— Posted on CoinMarketCap · {when}" + (f"\n{link}" if link else "")
    return f"{text}\n\n{tail}".strip()


def post_tags(post: dict) -> list[str]:
    return [s.lower() for s in (post.get("symbols") or [])[:4]] + ["coinmarketcap"]


def digest(body: str, tags: list[str]) -> str:
    return hashlib.sha256((body + "\x00" + ",".join(tags)).encode()).hexdigest()[:16]


def sync_posts(platform: Platform, session: Session, posts: list[dict], published: dict[str, Any],
               limit: int = POSTS_PER_ROUND) -> tuple[dict[str, Any], dict[str, int]]:
    """Upserts the newest [limit] posts as the signed-in trader.

    [published] maps a CoinMarketCap post id to {post_id, digest, at}: what an
    earlier round published. Returns the updated map and counts.
    """
    published = dict(published or {})
    counts = {"created": 0, "updated": 0, "unchanged": 0, "failed": 0}
    newest = sorted(posts, key=lambda p: p.get("timestamp") or "", reverse=True)[:limit]
    # Publish oldest first, so the platform's feed keeps their order.
    for post in reversed(newest):
        cmc_id = str(post.get("id") or "")
        if not cmc_id or not (post.get("text") or "").strip():
            continue
        body, tags = post_body(post), post_tags(post)
        want = digest(body, tags)
        prior = published.get(cmc_id) or {}
        try:
            if prior.get("post_id"):
                exists = True
                try:
                    platform.call(session, "posts", "post_get", {"post": prior["post_id"]})
                except PlatformError as e:
                    if e.status != 404 and e.code != "NOT_FOUND":
                        raise
                    exists = False
                if exists and prior.get("digest") == want:
                    counts["unchanged"] += 1
                    continue
                if exists:
                    platform.call(session, "posts", "post_delete", {"post": prior["post_id"]})
            out = platform.call(session, "posts", "post_create", {"body": body, "tags": tags})
            published[cmc_id] = {"post_id": out.get("post_id"), "digest": want, "at": post.get("timestamp")}
            counts["updated" if prior.get("post_id") else "created"] += 1
        except PlatformError:
            counts["failed"] += 1
    if len(published) > REMEMBERED_POSTS:
        keep = sorted(published.items(), key=lambda kv: kv[1].get("at") or "", reverse=True)[:REMEMBERED_POSTS]
        published = dict(keep)
    return published, counts


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
