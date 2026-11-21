"""The Peyda Analyst, reached the way a platform frontend's server reaches a
space agent: through the Decillion API, with the signed-in person's own token
(never the app key), so the turn is billed to and recorded for that person."""
from __future__ import annotations

import asyncio
import os
import re
import sys
from pathlib import Path
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parent.parent


def _sdk_dirs() -> list[Path]:
    """Where the Decillion server SDK may be: the app's own copy (an app built by
    appui_create has one in vendor/), then where the project's computer installs it."""
    found = [ROOT / "vendor" / "decillion-sdk"]
    if os.environ.get("DECILLION_SDK_DIR"):
        found.append(Path(os.environ["DECILLION_SDK_DIR"]))
    found += [Path("/opt/decillion-appui/sdk"), Path("/workspace/appui/sdk")]
    return found


USER_AGENT = "Peyda/1.0 (Decillion app)"
_identified = False


def identify_to_the_node() -> None:
    """Gives `urllib` a real User-Agent. The Decillion SDK calls the node with `urllib`,
    whose default `Python-urllib/3.x` is refused by Cloudflare (error 1010, a 403 with no
    JSON body, which the SDK reports as a bare `Forbidden`) on nodes served through it."""
    global _identified
    if _identified:
        return
    import urllib.request

    opener = urllib.request.build_opener()
    opener.addheaders = [("User-Agent", USER_AGENT)]
    urllib.request.install_opener(opener)
    _identified = True


def _decillion_class() -> Any:
    try:
        from decillion_server import Decillion  # already importable
        return Decillion
    except ImportError:
        pass
    for d in _sdk_dirs():
        if (d / "decillion_server.py").is_file():
            if str(d) not in sys.path:
                sys.path.insert(0, str(d))
            from decillion_server import Decillion

            return Decillion
    raise ImportError("the Decillion server SDK (decillion_server.py) was not found in: " + ", ".join(str(d) for d in _sdk_dirs()))


def normalize_api_url(url: str) -> str:
    """The node's app API root, `<node>/appapi/v1`, from whatever X-Decillion-Api carried.

    A node whose LLM-proxy URL ends in `/deepagents/v1/llm` once handed apps
    `<node>/deepagents/v1/llm/appapi/v1`, which answers "route not found". The
    app API always lives at `<scheme>://<host>/appapi/v1`, so anything between
    the host and `/appapi/v1` is dropped.

    `PEYDA_NODE_URL` (the workflow's `node_url` input) overrides the node's address
    outright: a node whose computers run outside its network hands apps an internal
    host name (`http://decillion:8080`) that they cannot resolve."""
    node = os.environ.get("PEYDA_NODE_URL", "").strip().rstrip("/")
    if node:
        return f"{node}/appapi/v1"
    m = re.match(r"^(https?://[^/]+)(?:/.*)?/appapi/v1/?$", (url or "").strip())
    return f"{m.group(1)}/appapi/v1" if m else (url or "")


class DecillionAnalyst:
    """`ask` is a fresh, isolated conversation each time; the chat's history
    travels with it, which is what makes the thread continue."""

    def __init__(self, headers: Mapping[str, str]) -> None:
        fixed = {k.lower(): v for k, v in headers.items()}
        if fixed.get("x-decillion-api"):
            fixed["x-decillion-api"] = normalize_api_url(fixed["x-decillion-api"])
        identify_to_the_node()
        self._decillion = _decillion_class().from_headers(fixed)

    async def ask(self, prompt: str, history: list[dict[str, str]]) -> str:
        def call() -> str:
            reply = self._decillion.ask("Peyda Analyst", prompt, history=history or None)
            return str(reply.get("reply", ""))

        return await asyncio.to_thread(call)


def signed_in(headers: Mapping[str, str]) -> bool:
    return bool(headers.get("x-decillion-user-token") and headers.get("x-decillion-user"))
