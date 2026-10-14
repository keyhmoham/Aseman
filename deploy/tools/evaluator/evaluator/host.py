"""The node, as the evaluator reaches it.

A managed tool acts on the platform only inside the scope of a call the node
made to it: every call carries a signed scope token (X-Tradera-Scope, valid
for 15 minutes) the backend hands back to the tool gateway
(POST /tools/v1/runtime/host) to run an allowed action as the tool's own
account — its key-value store (bots.kv_*), asking the space's agents
(spaces.ask), listing members.

The evaluator works in the background between calls, so it keeps the
freshest scopes it was given: any scope for its own KV store, and a space
scope (one from a call made in a space — the admins space, by its routine or
an administrator) for asking the space's lead agent. The admins space's
routine calls `tick` every few minutes, which keeps both fresh.
"""

from __future__ import annotations

import base64
import json
import os
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field


class HostError(Exception):
    def __init__(self, message: str, status: int = 0, code: str = ""):
        super().__init__(message)
        self.status = status
        self.code = code

    @property
    def not_found(self) -> bool:
        return self.status == 404 or self.code.lower() in ("not_found", "notfound")


@dataclass
class Scope:
    """The execution scope of one call, as the node sent it."""

    token: str = ""
    tool: str = ""
    actor: str = ""
    space: str = ""
    room: str = ""
    agent: str = ""
    exp: float = 0.0

    @classmethod
    def from_headers(cls, headers) -> "Scope":
        def h(name: str) -> str:
            return str(headers.get(name) or "").strip()

        sc = cls(token=h("X-Tradera-Scope"), tool=h("X-Tradera-Tool"), actor=h("X-Tradera-Actor"),
                 space=h("X-Tradera-Space"), room=h("X-Tradera-Room"), agent=h("X-Tradera-Agent"))
        sc.exp = token_expiry(sc.token)
        return sc

    def valid(self, margin: float = 60.0) -> bool:
        return bool(self.token) and self.exp - time.time() > margin


def token_expiry(token: str) -> float:
    """The exp of a node scope token (base64url JSON body "." signature)."""
    body = (token or "").split(".", 1)[0]
    if not body:
        return 0.0
    try:
        raw = base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))
        return float(json.loads(raw).get("exp") or 0)
    except Exception:
        return 0.0


@dataclass
class ScopeKeeper:
    """The freshest scopes the node gave the evaluator."""

    any_scope: Scope = field(default_factory=Scope)
    space_scope: Scope = field(default_factory=Scope)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def offer(self, sc: Scope) -> None:
        if not sc.token:
            return
        with self._lock:
            if sc.exp >= self.any_scope.exp:
                self.any_scope = sc
            if sc.space and sc.exp >= self.space_scope.exp:
                self.space_scope = sc

    def kv(self) -> Scope | None:
        with self._lock:
            for sc in (self.any_scope, self.space_scope):
                if sc.valid():
                    return sc
        return None

    def space(self) -> Scope | None:
        with self._lock:
            return self.space_scope if self.space_scope.valid() else None


class Node:
    """The tool runtime gateway of the node."""

    def __init__(self, url: str | None = None, timeout: float = 900.0):
        self.url = (url or os.environ.get("TRADERA_NODE_URL") or "http://tradera:8080").rstrip("/")
        self.timeout = timeout

    def call(self, scope: Scope, namespace: str, action: str, body: dict | None = None,
             timeout: float | None = None) -> dict:
        if not scope or not scope.token:
            raise HostError("no scope to act in: the evaluator has not been called recently")
        data = json.dumps({"namespace": namespace, "action": action, "body": body or {}}).encode()
        req = urllib.request.Request(f"{self.url}/tools/v1/runtime/host", data=data, method="POST",
                                     headers={"Authorization": f"Bearer {scope.token}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as res:
                raw = res.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                err = (json.loads(raw) or {}).get("error") or {}
            except Exception:
                err = {}
            raise HostError(err.get("message") or f"{namespace}.{action} failed: HTTP {e.code}",
                            status=e.code, code=str(err.get("code") or "")) from None
        except urllib.error.URLError as e:
            raise HostError(f"node unreachable: {e.reason}") from None
        try:
            return json.loads(raw) if raw.strip() else {}
        except Exception:
            return {"text": raw.decode("utf-8", "replace")}
