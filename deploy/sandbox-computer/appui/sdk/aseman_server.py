"""Aseman server SDK for Python app backends (see ASEMAN_API.md, "From your server").

    from aseman_server import Aseman
    # Serving a request: act for (and bill) the person using the app.
    aseman = Aseman.from_headers(request.headers)
    reply = aseman.ask("research", "Summarise ...")["reply"]
    # Work nobody is in front of: act for (and bill) the person who asked for the app.
    bg = Aseman.app()

Standard library only. Settings come from the environment (ASEMAN_API_URL,
ASEMAN_APP_KEY), else from .aseman/server.env in the working directory.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Mapping

USER_TOKEN = "X-Aseman-User-Token"


class AsemanError(Exception):
    def __init__(self, message: str, status: int = 0, op: str = "") -> None:
        super().__init__(message)
        self.status, self.op = status, op


def _settings() -> dict[str, str]:
    found: dict[str, str] = {}
    try:
        with open(os.path.join(os.getcwd(), ".aseman", "server.env"), encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$", line)
                if m:
                    found[m.group(1)] = m.group(2).strip("\"'")
    except OSError:
        pass
    return {k: os.environ.get(k) or found.get(k, "") for k in ("ASEMAN_API_URL", "ASEMAN_APP_KEY")}


def _header(headers: Mapping[str, str] | None, name: str) -> str:
    if not headers:
        return ""
    for k, v in headers.items():
        if k.lower() == name.lower():
            return v
    return ""


def parse_json(text: Any) -> Any:
    """The first JSON value in an agent's reply (fenced ```json or bare)."""
    if isinstance(text, (dict, list)):
        return text
    s = str(text or "")
    fenced = re.search(r"```(?:json)?\s*([\s\S]*?)```", s, re.I)
    for c in (fenced.group(1) if fenced else None, s):
        if not c:
            continue
        start = min((i for i in (c.find("{"), c.find("[")) if i >= 0), default=-1)
        if start < 0:
            continue
        for end in range(len(c), start, -1):
            if c[end - 1] not in "}]":
                continue
            try:
                return json.loads(c[start:end])
            except ValueError:
                continue
    raise AsemanError("the agent's reply has no JSON", 0, "ask")


class Aseman:
    """A client of the space's page API, acting as one person (who pays)."""

    def __init__(self, token: str, url: str = "", user: dict[str, str] | None = None,
                 platform: dict[str, str] | None = None) -> None:
        if not token:
            raise AsemanError("no Aseman credential: serve a request from the Aseman preview "
                              "(it carries X-Aseman-User-Token) or set ASEMAN_APP_KEY", 401)
        self.token = token
        self.url = (url or _settings()["ASEMAN_API_URL"]).rstrip("/")
        if not self.url:
            raise AsemanError("ASEMAN_API_URL is not set")
        # Who the app serves; in a platform's frontend, the platform's person
        # (calls run as, and bill, the frontend's publisher, within its wiring).
        self.user = user
        self.platform = platform

    @classmethod
    def from_headers(cls, headers: Mapping[str, str]) -> "Aseman":
        """Acts for the person whose request carried [headers]; billed to them."""
        uid = _header(headers, "X-Aseman-User")
        user = {"id": uid, "handle": _header(headers, "X-Aseman-User-Handle")} if uid else None
        return cls(_header(headers, USER_TOKEN), _header(headers, "X-Aseman-Api"), user,
                   cls.platform_of(headers))

    @staticmethod
    def platform_of(headers: Mapping[str, str]) -> dict[str, str] | None:
        """The sub-platform a request came through ({slug, id, name}), or None."""
        slug = _header(headers, "X-Aseman-Platform")
        if not slug:
            return None
        return {"slug": slug, "id": _header(headers, "X-Aseman-Platform-Id"),
                "name": _header(headers, "X-Aseman-Platform-Name")}

    @classmethod
    def app(cls, key: str = "", url: str = "") -> "Aseman":
        """Acts with the app's key for background work; billed to the person who asked for the app."""
        return cls(key or _settings()["ASEMAN_APP_KEY"], url)

    @staticmethod
    def has_user(headers: Mapping[str, str]) -> bool:
        return bool(_header(headers, USER_TOKEN))

    def request(self, op: str, *, method: str = "GET", body: Any = None,
                query: Mapping[str, Any] | None = None, timeout: float = 120) -> Any:
        url = self.url + "/" + op
        if query:
            url += "?" + urllib.parse.urlencode({k: v if isinstance(v, str) else json.dumps(v)
                                                 for k, v in query.items() if v is not None})
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token, **({"Content-Type": "application/json"} if data else {})})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as exc:
            try:
                msg = json.loads(exc.read() or b"{}").get("error") or exc.reason
            except ValueError:
                msg = exc.reason
            raise AsemanError(str(msg), exc.code, op) from None
        except (urllib.error.URLError, TimeoutError) as exc:
            raise AsemanError(str(exc), 0, op) from None

    def context(self) -> Any:
        return self.request("context")

    def tools(self) -> list[Any]:
        return self.request("tools").get("tools") or []

    def microtools(self, tool: str) -> list[Any]:
        return self.request("microtools", query={"tool": tool}).get("microtools") or []

    def agents(self) -> list[Any]:
        return self.request("agents").get("agents") or []

    def call(self, tool: str, microtool: str, args: Mapping[str, Any] | None = None) -> Any:
        """A space app's microtool; the unwrapped result (often text)."""
        return self.request("call", method="POST", body={"tool": tool, "microtool": microtool,
                                                        "args": dict(args or {})}).get("result")

    def ask(self, agent: str, prompt: str, history: list[dict[str, str]] | None = None,
            timeout: float = 360) -> dict[str, Any]:
        """Asks a space agent in a fresh, isolated conversation."""
        body: dict[str, Any] = {"agent": agent, "prompt": prompt}
        if history:
            body["history"] = history
        return self.request("ask", method="POST", body=body, timeout=timeout)

    def ask_json(self, agent: str, prompt: str, data: Any = None, **kw: Any) -> Any:
        text = prompt + (("\n\nData (JSON):\n" + json.dumps(data)) if data is not None else "")
        return parse_json(self.ask(agent, text + "\n\nAnswer only with JSON, no prose.", **kw)["reply"])
