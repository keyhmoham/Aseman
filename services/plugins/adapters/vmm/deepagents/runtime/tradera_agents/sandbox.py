"""The space's shared sandbox as a deep agents backend.

Every agent of a space — the lead and every specialist — works on the same
machine: the space sandbox the platform runs. A command reaches it as an ask
of the space's sandbox bot (``spaces.ask`` with ``raw``), which is the same
agent-to-tool transport every other tool uses, billed and logged the same way.
The deep agents filesystem tools (ls, read_file, write_file, edit_file, glob,
grep) run on top of ``execute``, so the shell, the files and every agent's
view of them are one and the same.

The machine sleeps when nobody uses it, and a command wakes it. Files are not
a reason to wake it: reading, writing and editing a file (and what a turn
needs before the agent has decided to do anything, its skills) go through the
project's stored files, which the platform reads and changes while the
computer sleeps. Only running something (a command, a search over the files)
starts it. Reads and edits run deep agents' own scripts on a copy of the
stored file, so they behave exactly as they would on the computer.
"""

from __future__ import annotations

import asyncio
import base64
import os
import shlex
import subprocess
import tempfile

from typing import Any

from deepagents.backends.protocol import (
    DeleteResult,
    EditResult,
    ExecuteResponse,
    FileDownloadResponse,
    FileUploadResponse,
    LsResult,
    ReadResult,
    WriteResult,
)
from deepagents.backends.sandbox import (
    _EDIT_INLINE_MAX_BYTES,
    BaseSandbox,
    _build_edit_inline_cmd,
    _build_edit_tmpfile_cmd,
    _build_read_cmd,
    _parse_edit_output,
    _parse_read_output,
)

from .context import TurnContext
from .gateway import GatewayError

#: Where the space's agents keep their shared work.
WORKSPACE = os.environ.get("TRADERA_WORKSPACE", "/workspace").rstrip("/") or "/workspace"

# Bytes per command when moving files in and out (kept well under ARG_MAX).
_CHUNK = 48 * 1024

# How long deep agents' read and edit scripts may take on a stored copy.
_LOCAL_TIMEOUT = 60


def _run_here(command: str) -> str:
    """Runs one of deep agents' own file scripts (a fixed template, its
    arguments base64-encoded) here, on a copy of a stored file."""
    done = subprocess.run(["sh", "-c", command], capture_output=True, text=True, timeout=_LOCAL_TIMEOUT, check=False)
    return done.stdout


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

    def read(self, file_path: str, offset: int = 0, limit: int = 2000) -> ReadResult:
        data = self.read_stored(file_path)
        if data is None:
            # Missing, a folder, or not readable that way: the computer says.
            return super().read(file_path, offset, limit)
        with tempfile.TemporaryDirectory() as tmp:
            copy = os.path.join(tmp, os.path.basename(file_path) or "file")
            with open(copy, "wb") as f:
                f.write(data)
            return _parse_read_output(_run_here(_build_read_cmd(copy, offset, limit)), file_path)

    async def aread(self, file_path: str, offset: int = 0, limit: int = 2000) -> ReadResult:
        return await asyncio.to_thread(self.read, file_path, offset, limit)

    def write(self, file_path: str, content: str) -> WriteResult:
        if self._stored_kind(file_path) in ("file", "missing") and self.store_files([(file_path, content.encode("utf-8"))]):
            return WriteResult(path=file_path)
        return super().write(file_path, content)

    async def awrite(self, file_path: str, content: str) -> WriteResult:
        return await asyncio.to_thread(self.write, file_path, content)

    def edit(self, file_path: str, old_string: str, new_string: str, replace_all: bool = False) -> EditResult:  # noqa: FBT001, FBT002
        data = self.read_stored(file_path) if old_string else None
        if data is None:
            return super().edit(file_path, old_string, new_string, replace_all)
        with tempfile.TemporaryDirectory() as tmp:
            copy = os.path.join(tmp, os.path.basename(file_path) or "file")
            with open(copy, "wb") as f:
                f.write(data)
            if len(old_string.encode()) + len(new_string.encode()) <= _EDIT_INLINE_MAX_BYTES:
                command = _build_edit_inline_cmd(copy, old_string, new_string, replace_all=replace_all)
            else:
                old_tmp, new_tmp = os.path.join(tmp, ".old"), os.path.join(tmp, ".new")
                with open(old_tmp, "w", encoding="utf-8") as f:
                    f.write(old_string)
                with open(new_tmp, "w", encoding="utf-8") as f:
                    f.write(new_string)
                command = _build_edit_tmpfile_cmd(copy, old_tmp, new_tmp, replace_all=replace_all)
            result = _parse_edit_output(_run_here(command), file_path, old_string)
            if result.error:
                return result
            with open(copy, "rb") as f:
                edited = f.read()
        if edited == data or self.store_files([(file_path, edited)]):
            return result
        # Not stored: nothing changed, so the computer makes the same edit.
        return super().edit(file_path, old_string, new_string, replace_all)

    async def aedit(self, file_path: str, old_string: str, new_string: str, replace_all: bool = False) -> EditResult:  # noqa: FBT001, FBT002
        return await asyncio.to_thread(self.edit, file_path, old_string, new_string, replace_all)

    def delete(self, file_path: str) -> DeleteResult:
        kind = self._stored_kind(file_path)
        if kind == "missing":
            return DeleteResult(error=f"Error: '{file_path}' not found")
        if kind is not None:
            out = self._files("delete", file_path)
            if out is not None and out.get("ok") is not False:
                return DeleteResult(path=file_path)
        return super().delete(file_path)

    async def adelete(self, file_path: str) -> DeleteResult:
        return await asyncio.to_thread(self.delete, file_path)

    def _stored_kind(self, path: str) -> str | None:
        """What path is in the stored files: "dir", "file" or "missing";
        None when the stored files cannot say (the computer then does)."""
        parent, _, name = path.rstrip("/").rpartition("/")
        if not name:
            return None
        out = self._files("list", parent or "/")
        if out is None or out.get("unreadable"):
            return None
        if out.get("missing"):
            return "missing"
        if "items" not in out:
            return None
        for e in out.get("items") or []:
            if e.get("name") == name:
                return "dir" if e.get("type") == "dir" else "file"
        return "missing"

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
