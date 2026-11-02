"""Persistent OpenCode authentication for the agentic engine.

Each turn keeps its own HOME/XDG data directories so concurrent turns do not
share OpenCode's session database. Authentication must outlive a turn, so it
lives in a persistent place and is copied into the turn's data directory
before OpenCode starts.

OpenCode v2 stores credentials in its SQLite DB. A legacy ``auth.json`` alone
is not enough for ``opencode run --standalone``: the engine also runs
``opencode auth import`` so the Go key is active for ``opencode-go/*`` models.

Sources, first match wins:

* ``ASEMAN_OPENCODE_ENGINE_AUTH``: an ``auth.json`` file, or a directory that
  contains one (an OpenCode data directory also works).
* ``ASEMAN_OPENCODE_ENGINE_AUTH_HOME``: a persistent auth home, defaulting to
  ``<engine home>/auth``. The file may be at ``auth.json`` or at
  ``.local/share/opencode/auth.json`` (where ``opencode auth login`` writes
  when HOME/XDG_DATA_HOME point there).
* ``ASEMAN_OPENCODE_ENGINE_API_KEY``: an OpenCode Go API key. When no auth
  file is present, it is written into the auth home as ``opencode-go``.

This is OpenCode's own credential (for example ``opencode-go``); it is not
the platform's metered ``ASEMAN_LLM_*`` gateway, which the engine still
refuses.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path

AUTH_NAME = "auth.json"
CREDENTIALS_NAME = "credentials.json"
AUTH_HOME_ENV = "ASEMAN_OPENCODE_ENGINE_AUTH_HOME"
AUTH_FILE_ENV = "ASEMAN_OPENCODE_ENGINE_AUTH"
API_KEY_ENV = "ASEMAN_OPENCODE_ENGINE_API_KEY"
# OpenCode's paid gateway provider id used when materializing from an API key.
GO_PROVIDER = "opencode-go"
GO_CREDENTIAL_ID = "cred_aseman_opencode_go"

log = logging.getLogger("aseman.agents.opencode_engine.auth")


def auth_home(engine_home: Path) -> Path:
    """The persistent directory that keeps the OpenCode credential."""
    override = os.environ.get(AUTH_HOME_ENV, "").strip()
    return Path(override) if override else Path(engine_home) / "auth"


def _candidates(root: Path) -> tuple[Path, ...]:
    return (
        root / AUTH_NAME,
        root / "opencode" / AUTH_NAME,
        root / ".local" / "share" / "opencode" / AUTH_NAME,
    )


def source(engine_home: Path) -> Path | None:
    """The persistent auth file to seed from, if one is configured."""
    override = os.environ.get(AUTH_FILE_ENV, "").strip()
    if override:
        path = Path(override)
        if path.is_file():
            return path
        if path.is_dir():
            for candidate in _candidates(path):
                if candidate.is_file():
                    return candidate
        return None
    for candidate in _candidates(auth_home(engine_home)):
        if candidate.is_file():
            return candidate
    return None


def _api_key() -> str:
    return os.environ.get(API_KEY_ENV, "").strip()


def _key_from_auth_file(path: Path) -> str:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    entry = data.get(GO_PROVIDER)
    if isinstance(entry, dict):
        return str(entry.get("key") or entry.get("token") or "").strip()
    return ""


def credentials_export(engine_home: Path) -> Path | None:
    """Write an ``opencode auth import`` file for the Go API key, if available."""
    key = _api_key()
    if not key:
        src = source(engine_home)
        if src is not None:
            key = _key_from_auth_file(src)
    if not key:
        return None
    dest = auth_home(engine_home) / CREDENTIALS_NAME
    payload = [{
        "id": GO_CREDENTIAL_ID,
        "integrationID": GO_PROVIDER,
        "label": "Aseman OpenCode Go",
        "active": True,
        "value": {"type": "key", "key": key},
    }]
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(payload)
        if not dest.is_file() or dest.read_text(encoding="utf-8") != text:
            dest.write_text(text, encoding="utf-8")
        os.chmod(dest, 0o600)
    except OSError as exc:
        log.warning("could not write OpenCode credentials export: %s", exc)
        return None
    return dest


def ensure(engine_home: Path) -> Path | None:
    """Make sure a persistent auth.json exists.

    Prefer an already-configured file. Otherwise materialize one from
    ``ASEMAN_OPENCODE_ENGINE_API_KEY`` into the auth home.
    """
    existing = source(engine_home)
    if existing is not None:
        credentials_export(engine_home)
        return existing
    key = _api_key()
    if not key:
        return None
    dest = auth_home(engine_home) / ".local" / "share" / "opencode" / AUTH_NAME
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({GO_PROVIDER: {"type": "api", "key": key}})
        if not dest.is_file() or dest.read_text(encoding="utf-8") != payload:
            dest.write_text(payload, encoding="utf-8")
        os.chmod(dest, 0o600)
    except OSError as exc:
        log.warning("could not write OpenCode engine auth: %s", exc)
        return None
    credentials_export(engine_home)
    return dest


def _import_into(process_home: Path, export_path: Path, *, binary: str) -> bool:
    """Load the Go credential into this turn's OpenCode v2 database."""
    env = {
        "HOME": str(process_home),
        "PATH": os.environ.get("PATH", ""),
        "XDG_CONFIG_HOME": str(process_home / ".config"),
        "XDG_DATA_HOME": str(process_home / ".local" / "share"),
        "XDG_STATE_HOME": str(process_home / ".local" / "state"),
        "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
        "PWD": str(process_home),
    }
    try:
        done = subprocess.run(
            [binary, "auth", "import", "--standalone", str(export_path)],
            capture_output=True, text=True, timeout=30, env=env, cwd=str(process_home), check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.warning("opencode auth import failed: %s", exc)
        return False
    if done.returncode != 0:
        detail = (done.stderr or done.stdout or "").strip()[:300]
        log.warning("opencode auth import exited %s: %s", done.returncode, detail)
        return False
    return True


def seed(process_home: Path, engine_home: Path, *, binary: str | None = None) -> Path | None:
    """Copy persistent auth into this turn's OpenCode data directory and import it.

    Returns the seeded ``auth.json`` path, or ``None`` when no persistent auth
    is set up. OpenCode reads ``$XDG_DATA_HOME/opencode/auth.json``; v2 also
    needs the credential in its DB, which ``auth import`` writes.
    """
    ensure(engine_home)
    source_path = source(engine_home)
    if source_path is None:
        return None
    dest = Path(process_home) / ".local" / "share" / "opencode" / AUTH_NAME
    try:
        if dest.resolve() != source_path.resolve():
            data = source_path.read_bytes()
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.is_file() or dest.read_bytes() != data:
                dest.write_bytes(data)
            os.chmod(dest, 0o600)
    except OSError:
        return None
    export_path = credentials_export(engine_home)
    if export_path is not None:
        from .models import binary as default_binary
        _import_into(process_home, export_path, binary=binary or default_binary())
    return dest


def sync_back(process_home: Path, engine_home: Path) -> None:
    """Keep a refreshed credential in the persistent file.

    OAuth credentials can rotate while OpenCode runs. The copy is the one
    OpenCode updates, so write it back when it is newer; a read-only mount
    simply keeps the original.
    """
    source_path = source(engine_home)
    if source_path is None:
        return
    dest = Path(process_home) / ".local" / "share" / "opencode" / AUTH_NAME
    try:
        if not dest.is_file():
            return
        if dest.stat().st_mtime_ns <= source_path.stat().st_mtime_ns:
            return
        source_path.write_bytes(dest.read_bytes())
        os.chmod(source_path, 0o600)
    except OSError:
        pass


def has_go_auth(engine_home: Path) -> bool:
    """Whether a Go API key is available for ``opencode-go/*`` models."""
    ensure(engine_home)
    return credentials_export(engine_home) is not None
