"""The evaluator's database: the tool bot's own key-value store on the node.

Every value is JSON (the node keeps it in a JSONB column). Keys:

  evaluator/config            settings (interval, LLM, agent, proxy, limits)
  evaluator/session           the CoinMarketCap browser session (Playwright
                              storage_state: cookies + localStorage)
  evaluator/traders           the trader handles, in the order admins added them
  evaluator/trader/<handle>   one trader: profile link, status, the last
                              reliability report and its score summary

The Tradera client reads the leaderboard through the node
(tools.traders_leaderboard / tools.trader_profile), which asks this tool's
read-only microtools; they read these keys.
"""

from __future__ import annotations

import json
import re
from typing import Any, Callable

from .host import HostError, Node, Scope

PREFIX = "evaluator/"
CONFIG = PREFIX + "config"
SESSION = PREFIX + "session"
TRADERS = PREFIX + "traders"
TRADER = PREFIX + "trader/"

DEFAULT_CONFIG: dict[str, Any] = {
    # How often each trader is evaluated again.
    "interval_hours": 12,
    # The most posts given to the model per evaluation.
    "max_posts": 40,
    # Optional OpenAI-compatible endpoint; without it the space's lead agent
    # (the built-in "tradera" agent) does the analysis.
    "llm_base_url": "",
    "llm_api_key": "",
    "llm_model": "",
    # Optional agent bot id to ask instead of the space's lead agent.
    "agent_bot": "",
    # Optional HTTP proxy for the browser (CMC is geo-blocked in places).
    "proxy": "",
}

_HANDLE = re.compile(r"/community/profile/([^/?#]+)")


def handle_of(profile_link: str) -> str:
    """The trader handle in a CoinMarketCap community profile URL."""
    m = _HANDLE.search(profile_link or "")
    return m.group(1).strip().lower() if m else ""


def valid_profile_link(link: str) -> bool:
    link = (link or "").strip()
    return link.startswith(("https://coinmarketcap.com/", "https://www.coinmarketcap.com/")) and bool(handle_of(link))


class Store:
    """KV access in a scope, picked per operation (the freshest one)."""

    def __init__(self, node: Node, scope: Callable[[], Scope | None]):
        self.node = node
        self.scope = scope

    def _scope(self) -> Scope:
        sc = self.scope()
        if sc is None:
            raise HostError("no scope to act in: the evaluator has not been called recently")
        return sc

    def get(self, key: str, default: Any = None) -> Any:
        try:
            out = self.node.call(self._scope(), "bots", "kv_get", {"key": key}, timeout=30)
        except HostError as e:
            if e.not_found:
                return default
            raise
        return _decode(out.get("value"), default)

    def set(self, key: str, value: Any) -> None:
        self.node.call(self._scope(), "bots", "kv_set", {"key": key, "value": json.dumps(value)}, timeout=30)

    def delete(self, key: str) -> None:
        try:
            self.node.call(self._scope(), "bots", "kv_delete", {"key": key}, timeout=30)
        except HostError as e:
            if not e.not_found:
                raise

    def items(self, prefix: str = "") -> dict[str, Any]:
        """Every key (with prefix) and its value."""
        out: dict[str, Any] = {}
        offset = 0
        while True:
            page = self.node.call(self._scope(), "bots", "kv_list", {"limit": 200, "offset": offset}, timeout=30)
            rows = page.get("items") or []
            for row in rows:
                key = row.get("key") or ""
                if key.startswith(prefix):
                    out[key] = _decode(row.get("value"), None)
            if len(rows) < 200:
                return out
            offset += len(rows)

    # --- typed helpers ---------------------------------------------------------

    def config(self) -> dict:
        cfg = dict(DEFAULT_CONFIG)
        stored = self.get(CONFIG, {})
        if isinstance(stored, dict):
            cfg.update({k: v for k, v in stored.items() if v is not None})
        return cfg

    def handles(self) -> list[str]:
        value = self.get(TRADERS, [])
        return [h for h in value if isinstance(h, str)] if isinstance(value, list) else []

    def trader(self, handle: str) -> dict | None:
        value = self.get(TRADER + handle)
        return value if isinstance(value, dict) else None

    def put_trader(self, record: dict) -> None:
        self.set(TRADER + record["handle"], record)

    def traders(self) -> list[dict]:
        """Every trader record, in the order admins added them."""
        order = self.handles()
        found = {k[len(TRADER):]: v for k, v in self.items(TRADER).items() if isinstance(v, dict)}
        out = [found[h] for h in order if h in found]
        out += [v for h, v in found.items() if h not in order]
        return out


def _decode(value: Any, default: Any) -> Any:
    if value is None:
        return default
    if isinstance(value, str):
        try:
            return json.loads(value)
        except Exception:
            return value
    return value
