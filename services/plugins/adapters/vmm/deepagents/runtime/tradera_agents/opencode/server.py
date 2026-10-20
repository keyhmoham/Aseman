"""The self-hosted OpenCode server every agent runs on.

The runtime starts ``opencode serve`` beside itself (bound to the loopback
interface, behind a password only the runtime knows) and supervises it: it is
started with the runtime, restarted when it dies, and stopped with it. Or it
reaches one run elsewhere (``TRADERA_OPENCODE_URL``), which must then reach
this runtime back at ``TRADERA_OPENCODE_CALLBACK_URL``.

OpenCode keeps its sessions in its own database under the runtime's data
volume, so agents' conversations survive restarts like the rest of the
runtime's state. It reaches nothing but this runtime: its one model provider
is the runtime's relay to the node (relay.py) and its tools are the runtime's
MCP server (mcp.py); models catalogs, updates, LSP downloads and plugins of its
own are turned off.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import secrets
import shutil
from pathlib import Path
from typing import Any

import httpx

log = logging.getLogger("tradera.agents.opencode")

#: The pinned OpenCode version the runtime image carries (see ../../Dockerfile).
VERSION = "1.19.3"

# Everything OpenCode would otherwise fetch or read from outside: off.
QUIET_ENV = {
    "OPENCODE_DISABLE_AUTOUPDATE": "1",
    "OPENCODE_DISABLE_MODELS_FETCH": "1",
    "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
    "OPENCODE_DISABLE_CLAUDE_CODE": "1",
    "OPENCODE_DISABLE_EXTERNAL_SKILLS": "1",
    "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
    "OPENCODE_DISABLE_EMBEDDED_WEB_UI": "1",
    "OPENCODE_DISABLE_TERMINAL_TITLE": "1",
}

# A turn can run for as long as its delegated work does.
PROMPT_TIMEOUT = httpx.Timeout(connect=10.0, read=None, write=60.0, pool=30.0)
CALL_TIMEOUT = httpx.Timeout(connect=10.0, read=60.0, write=30.0, pool=30.0)
_LISTENING = re.compile(r"listening on (https?://\S+)")


class OpenCodeError(Exception):
    """OpenCode refused or failed a request."""

    def __init__(self, message: str, *, status: int = 0) -> None:
        super().__init__(message)
        self.status = status


def binary() -> str:
    """The opencode executable: TRADERA_OPENCODE_BIN, else on PATH."""
    return os.environ.get("TRADERA_OPENCODE_BIN", "").strip() or shutil.which("opencode") or "opencode"


class OpenCodeServer:
    """One OpenCode server: the process (when the runtime runs it) and its API."""

    def __init__(self, data_dir: str | Path, *, url: str = "", password: str = "", bin_path: str = "",
                 config_home: str = "", transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.data_dir = Path(data_dir)
        self.url = url.rstrip("/")
        self.external = bool(url)
        self.password = password or secrets.token_hex(16)
        self.bin_path = bin_path or binary()
        # The config home carries the pre-installed plugin SDK (see the Dockerfile),
        # so a project starts without going to npm.
        self.config_home = config_home or os.environ.get("TRADERA_OPENCODE_CONFIG_HOME", "")
        self._proc: asyncio.subprocess.Process | None = None
        self._watch: asyncio.Task[Any] | None = None
        self._stopping = False
        self._ready = asyncio.Event()
        self._transport = transport
        self._client: httpx.AsyncClient | None = None

    @classmethod
    def from_env(cls, data_dir: str | Path) -> OpenCodeServer:
        return cls(data_dir, url=os.environ.get("TRADERA_OPENCODE_URL", ""),
                   password=os.environ.get("TRADERA_OPENCODE_PASSWORD", ""))

    # --- the process ------------------------------------------------------------

    def env(self) -> dict[str, str]:
        home = self.data_dir / "opencode"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("TRADERA_", "OPENCODE_"))}
        env.update(QUIET_ENV)
        env.update({
            "XDG_DATA_HOME": str(home / "data"),
            "XDG_STATE_HOME": str(home / "state"),
            "XDG_CACHE_HOME": str(home / "cache"),
            "XDG_CONFIG_HOME": self.config_home or str(home / "config"),
            "OPENCODE_SERVER_PASSWORD": self.password,
        })
        # OpenCode reaches the runtime on the loopback interface: never through a proxy.
        for name in ("NO_PROXY", "no_proxy"):
            env[name] = ",".join(x for x in (env.get(name, ""), "127.0.0.1,localhost") if x)
        return env

    async def start(self, *, timeout: float = 60.0) -> None:
        if self.external:
            self._ready.set()
            return
        self._stopping = False
        await self._spawn(timeout)
        self._watch = asyncio.create_task(self._supervise())

    async def _spawn(self, timeout: float) -> None:
        self._ready.clear()
        for sub in ("data", "state", "cache", "config"):
            (self.data_dir / "opencode" / sub).mkdir(parents=True, exist_ok=True)
        self._proc = await asyncio.create_subprocess_exec(
            self.bin_path, "serve", "--hostname", "127.0.0.1", "--port", "0", "--log-level", "WARN",
            env=self.env(), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            start_new_session=True)
        assert self._proc.stdout is not None
        try:
            async with asyncio.timeout(timeout):
                while True:
                    line = (await self._proc.stdout.readline()).decode(errors="replace")
                    if not line:
                        raise OpenCodeError(f"opencode exited before listening (code {await self._proc.wait()})")
                    m = _LISTENING.search(line)
                    if m:
                        self.url = m.group(1).rstrip("/")
                        break
                    if line.strip() and "OPENCODE_SERVER_PASSWORD" not in line:
                        log.info("opencode: %s", line.strip()[:300])
        except TimeoutError as exc:
            self._proc.kill()
            raise OpenCodeError("opencode did not start listening in time") from exc
        self._drain = asyncio.create_task(self._pipe(self._proc))
        log.info("opencode %s serving at %s", VERSION, self.url)
        self._ready.set()

    async def _pipe(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            if line:
                log.info("opencode: %s", line[:500])

    async def _supervise(self) -> None:
        """Restart OpenCode when it dies (its sessions are on disk)."""
        while not self._stopping:
            proc = self._proc
            if proc is None:
                return
            code = await proc.wait()
            if self._stopping:
                return
            log.warning("opencode exited (code %s); restarting", code)
            await asyncio.sleep(1.0)
            try:
                await self._spawn(60.0)
            except Exception as exc:  # noqa: BLE001 - keep trying
                log.error("opencode restart failed: %s", exc)
                await asyncio.sleep(5.0)

    async def stop(self) -> None:
        self._stopping = True
        if self._watch is not None:
            self._watch.cancel()
        if self._client is not None:
            await self._client.aclose()
            self._client = None
        proc, self._proc = self._proc, None
        if proc is not None and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 10.0)
            except TimeoutError:
                proc.kill()

    # --- the API --------------------------------------------------------------

    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            # OpenCode is on the loopback interface (or reached directly): no proxy.
            self._client = httpx.AsyncClient(auth=("opencode", self.password), timeout=CALL_TIMEOUT,
                                             transport=self._transport, trust_env=False)
        return self._client

    async def request(self, method: str, path: str, directory: str, *, json: Any = None,
                      timeout: httpx.Timeout | None = None) -> Any:
        await asyncio.wait_for(self._ready.wait(), 120.0)
        resp = await self.client().request(method, self.url + path, params={"directory": directory}, json=json,
                                           timeout=timeout or CALL_TIMEOUT)
        if resp.status_code >= 300:
            raise OpenCodeError(f"opencode {method} {path}: {resp.status_code} {resp.text[:500]}",
                                status=resp.status_code)
        if not resp.content:
            return None
        try:
            return resp.json()
        except ValueError:
            return resp.text

    async def create_session(self, directory: str, title: str) -> str:
        out = await self.request("POST", "/session", directory, json={"title": title[:120]})
        return str(out["id"])

    async def session_exists(self, directory: str, session_id: str) -> bool:
        try:
            await self.request("GET", f"/session/{session_id}", directory)
            return True
        except OpenCodeError as exc:
            if exc.status in (400, 404):
                return False
            raise

    async def prompt(self, directory: str, session_id: str, *, parts: list[dict[str, Any]], system: str = "",
                     agent: str = "tradera") -> dict[str, Any]:
        """Send a message and wait until the agent's loop ends: {info, parts}."""
        body: dict[str, Any] = {"agent": agent, "parts": parts}
        if system:
            body["system"] = system
        return await self.request("POST", f"/session/{session_id}/message", directory, json=body,
                                  timeout=PROMPT_TIMEOUT)

    async def summarize(self, directory: str, session_id: str) -> None:
        """Compact a session's conversation (its next prompt starts from the summary)."""
        await self.request("POST", f"/session/{session_id}/summarize", directory,
                           json={"providerID": "tradera", "modelID": "agent"}, timeout=PROMPT_TIMEOUT)

    async def abort(self, directory: str, session_id: str) -> None:
        try:
            await self.request("POST", f"/session/{session_id}/abort", directory)
        except Exception as exc:  # noqa: BLE001 - best effort
            log.warning("opencode abort %s: %s", session_id, exc)

    async def messages(self, directory: str, session_id: str) -> list[dict[str, Any]]:
        out = await self.request("GET", f"/session/{session_id}/message", directory)
        return list(out or [])

    async def mcp_status(self, directory: str) -> dict[str, Any]:
        return dict(await self.request("GET", "/mcp", directory) or {})

    async def mcp_reconnect(self, directory: str, name: str) -> None:
        """Connect an MCP server afresh: it lists its tools again."""
        try:
            await self.request("POST", f"/mcp/{name}/disconnect", directory)
        except OpenCodeError:
            pass
        await self.request("POST", f"/mcp/{name}/connect", directory)

    async def dispose(self, directory: str) -> None:
        """Drop a project's instance: the next request loads its config again."""
        try:
            await self.request("POST", "/instance/dispose", directory)
        except OpenCodeError as exc:
            log.warning("opencode dispose %s: %s", directory, exc)
