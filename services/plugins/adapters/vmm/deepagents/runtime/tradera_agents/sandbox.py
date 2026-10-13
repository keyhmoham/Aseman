"""The space's shared sandbox as a deep agents backend.

Every agent of a space — the lead and every specialist — works on the same
machine: the space sandbox the platform runs. A command reaches it as an ask
of the space's sandbox bot (``spaces.ask`` with ``raw``), which is the same
agent-to-tool transport every other tool uses, billed and logged the same way.
The deep agents filesystem tools (ls, read_file, write_file, edit_file, glob,
grep) run on top of ``execute``, so the shell, the files and every agent's
view of them are one and the same.

The machine sleeps when nobody uses it, and a command wakes it. What a turn
needs before the agent has decided to do anything (its skills) is read from
the project's stored files instead, which does not wake it: a
message the model can answer on its own never starts the computer.
"""

from __future__ import annotations

import asyncio
import base64
import os
import shlex

from typing import Any

from deepagents.backends.protocol import ExecuteResponse, FileDownloadResponse, FileUploadResponse, LsResult
from deepagents.backends.sandbox import BaseSandbox

from .context import TurnContext
from .gateway import GatewayError

#: Where the space's agents keep their shared work.
WORKSPACE = os.environ.get("TRADERA_WORKSPACE", "/workspace").rstrip("/") or "/workspace"

# Bytes per command when moving files in and out (kept well under ARG_MAX).
_CHUNK = 48 * 1024


class FilesUnreadable(Exception):
    """The project's stored files could not be read just now."""


class TraderaSandbox(BaseSandbox):
    """A deep agents sandbox backend over the platform's space sandbox."""

    def __init__(self, ctx: TurnContext) -> None:
        self.ctx = ctx

    @property
    def id(self) -> str:
        return self.ctx.turn.sandbox_vm or f"space-{self.ctx.space}"

    def _ask(self, command: str) -> tuple[int, str]:
        if self.ctx.turn.no_sandbox:
            raise GatewayError("sandbox access is disabled for this request", code="permission_denied")
        if self.ctx.turn.no_memory and ("AGENTS.md" in command or ".tradera/" in command):
            raise GatewayError("saved space memory is disabled for this request", code="permission_denied")
        # A space that has no computer yet gets one on its first command.
        out = self.ctx.gateway.call_sync("spaces", "ask", {
            "space": self.ctx.space, "room": self.ctx.room, "bot": self.ctx.sandbox_bot or "sandbox",
            "body": command, "raw": True,
        })
        code = out.get("exit_code")
        output = out.get("output")
        if output is None:
            output = out.get("reply", "")
        return (int(code) if isinstance(code, int) else -1), str(output)

    def _files(self, operation: str, path: str, **extra: Any) -> dict[str, Any] | None:
        """One operation on the project's stored files, which never starts the
        computer. None means it could not be served this way (the file is
        outside the workspace, or the provider cannot reach a sleeping
        computer's files): the caller then goes through the shell."""
        if self.ctx.turn.no_sandbox or not (path == WORKSPACE or path.startswith(WORKSPACE + "/")):
            return None
        if self.ctx.turn.no_memory and ("AGENTS.md" in path or ".tradera/" in path):
            return None
        try:
            out = self.ctx.gateway.call_sync("spaces", "sandbox_files", {
                "space": self.ctx.space, "operation": operation, "path": path[len(WORKSPACE):].lstrip("/") or ".", **extra,
            })
        except GatewayError:
            return None
        # The provider keeps a sleeping computer's files readable but could not
        # read them just now: that is not worth starting the computer for.
        if out.get("unreadable"):
            return {"unreadable": True}
        return None if out.get("asleep") else out

    def ls(self, path: str) -> LsResult:
        out = self._files("list", path)
        if out is None:
            return super().ls(path)
        if out.get("missing") or out.get("unreadable"):
            return LsResult(entries=[])
        if "items" not in out:
            return super().ls(path)
        base = path.rstrip("/")
        return LsResult(entries=[
            {"path": f"{base}/{e.get('name', '')}", "is_dir": e.get("type") == "dir", "size": int(e.get("size") or 0)}
            for e in out.get("items") or [] if e.get("name")
        ])

    async def als(self, path: str) -> LsResult:
        return await asyncio.to_thread(self.ls, path)

    def read_stored(self, path: str) -> bytes | None:
        """A file from the project's stored files, without starting the
        computer; None when it is missing or cannot be read that way."""
        out = self._files("read", path)
        if not out or "data_base64" not in out:
            return None
        try:
            return base64.b64decode(out["data_base64"])
        except ValueError:
            return None

    def store_files(self, files: list[tuple[str, bytes]], *, only_missing: bool = False) -> bool:
        """Write files into the project's stored files without starting the
        computer. False when that is not possible here; nothing is half done
        that the shell path would not finish."""
        for path, data in files:
            if only_missing:
                have = self._files("read", path)
                if have is None:
                    return False
                if have.get("unreadable"):
                    raise FilesUnreadable(path)
                if not have.get("missing"):
                    continue
            out = self._files("write", path, data_base64=base64.b64encode(data).decode())
            if out is None or out.get("ok") is False:
                return False
        return True

    def execute(self, command: str, *, timeout: int | None = None) -> ExecuteResponse:
        if timeout:
            command = f"timeout {int(timeout)} sh -c {shlex.quote(command)}"
        try:
            code, output = self._ask(command)
        except GatewayError as exc:
            return ExecuteResponse(output=f"sandbox unavailable: {exc}", exit_code=None)
        return ExecuteResponse(output=output, exit_code=None if code < 0 else code)

    def upload_files(self, files: list[tuple[str, bytes]]) -> list[FileUploadResponse]:
        results: list[FileUploadResponse] = []
        for path, data in files:
            if not path.startswith("/"):
                results.append(FileUploadResponse(path=path, error="invalid_path"))
                continue
            quoted = shlex.quote(path)
            parent = shlex.quote(path.rsplit("/", 1)[0] or "/")
            error = None
            chunks = [data[i:i + _CHUNK] for i in range(0, len(data), _CHUNK)] or [b""]
            for index, chunk in enumerate(chunks):
                encoded = base64.b64encode(chunk).decode()
                redirect = ">" if index == 0 else ">>"
                cmd = f"mkdir -p {parent} && printf '%s' '{encoded}' | base64 -d {redirect} {quoted}"
                try:
                    code, output = self._ask(cmd)
                except GatewayError:
                    error = "permission_denied"
                    break
                if code != 0:
                    error = "is_directory" if "Is a directory" in output else "permission_denied"
                    break
            results.append(FileUploadResponse(path=path, error=error))
        return results

    def download_files(self, paths: list[str]) -> list[FileDownloadResponse]:
        results: list[FileDownloadResponse] = []
        for path in paths:
            stored = self._files("read", path)
            if stored is not None and (stored.get("missing") or stored.get("unreadable")):
                results.append(FileDownloadResponse(path=path, content=None, error="file_not_found"))
                continue
            if stored is not None and "data_base64" in stored:
                try:
                    results.append(FileDownloadResponse(path=path, content=base64.b64decode(stored["data_base64"]), error=None))
                    continue
                except ValueError:
                    pass
            quoted = shlex.quote(path)
            try:
                code, output = self._ask(
                    f"if [ -d {quoted} ]; then echo DIR; elif [ -f {quoted} ]; then wc -c < {quoted}; else echo MISSING; fi")
            except GatewayError:
                results.append(FileDownloadResponse(path=path, content=None, error="permission_denied"))
                continue
            state = output.strip()
            if code != 0 or state == "MISSING":
                results.append(FileDownloadResponse(path=path, content=None, error="file_not_found"))
                continue
            if state == "DIR":
                results.append(FileDownloadResponse(path=path, content=None, error="is_directory"))
                continue
            try:
                size = int(state.split()[0])
            except ValueError:
                results.append(FileDownloadResponse(path=path, content=None, error="permission_denied"))
                continue
            data = bytearray()
            error = None
            for offset in range(0, max(size, 1), _CHUNK):
                if size == 0:
                    break
                cmd = f"tail -c +{offset + 1} {quoted} | head -c {_CHUNK} | base64 | tr -d '\\n'"
                try:
                    code, output = self._ask(cmd)
                    if code != 0:
                        raise GatewayError(output)
                    data.extend(base64.b64decode(output.strip()))
                except (GatewayError, ValueError):
                    error = "permission_denied"
                    break
            results.append(FileDownloadResponse(path=path, content=None if error else bytes(data), error=error))
        return results
