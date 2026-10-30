"""Free models only: OpenCode's own gateway, never the platform LLM proxy."""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path

# Anything that isn't an ``opencode/…`` id that is free (the id says so, the cost is zero, or it
# comes from the OpenCode free list) is rejected by the CLI and engine. Platform ids like
# ``aseman/default`` must never be used here (and the programmer path uses them).
FREE_MARKERS = ("-free", "free", "big-pickle")
# Some OpenCode builds bundle specific ids even if verbose listing is empty.
BUNDLED_FREE = frozenset({"opencode/big-pickle", "opencode/beam-free"})

# Preference order when `opencode models` cannot be read. All of these are
# OpenCode's own free tier, not Aseman providers.
KNOWN_FREE: tuple[str, ...] = (
    "opencode/flint-40b-free",
    "opencode/nemotron-3.5-lightning-free",
    "opencode/beam-free",
    "opencode/big-pickle",
    "opencode/glm-5.3-flash-free",
    "opencode/mimo-v2.6-flash-free",
    "opencode/deepseek-v4.1-flash-free",
    "opencode/nemotron-3.5-super-vl-free",
)

# Substrings, best first, for the kind of work.
_PREFER: dict[str, tuple[str, ...]] = {
    "lead": ("flint", "nemotron", "beam", "glm", "big-pickle", "deepseek", "flash"),
    "swarm": ("flint", "nemotron", "beam", "glm", "deepseek", "flash", "big-pickle"),
    "app": ("flint", "nemotron", "beam", "mimo", "code", "deepseek", "flash"),
    "handoff": ("flint", "nemotron", "beam", "glm", "flash", "mini", "mimo"),
    "specialist": ("flint", "nemotron", "beam", "glm", "flash", "mini", "mimo", "deepseek"),
}

_ID = re.compile(r"opencode/[A-Za-z0-9._+-]+")
_COST = re.compile(r"([0-9]*\.?[0-9]+)\s*/\s*([0-9]*\.?[0-9]+)")


def is_free(model: str, cost: float | None = None) -> bool:
    mid = (model or "").strip()
    if not mid.startswith("opencode/") or "aseman" in mid:
        return False
    if mid in BUNDLED_FREE:
        return True
    if any(marker in mid for marker in FREE_MARKERS):
        return True
    if cost is not None and cost <= 0.0:
        return True
    return False


def parse_models_output(text: str) -> list[str]:
    """Model ids from ``opencode models`` output."""
    found: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        match = _ID.search(line)
        if not match:
            continue
        model = match.group(0)
        if model in seen:
            continue
        cost = None
        costs = [float(n) for n in _COST.findall(line)]
        if costs:
            cost = max(costs)
        if is_free(model, cost=cost):
            seen.add(model)
            found.append(model)
    return found


def _now() -> float:
    return time.time()


def fetch_free_models(binary: str, env: dict[str, str], *, cache: Path | None = None) -> list[str]:
    """Ask the OpenCode CLI which of its own models are free.

    A failure (no binary, no network) returns an empty list; the caller then
    uses KNOWN_FREE. The platform LLM gateway is not contacted.
    """
    if cache is not None and cache.is_file():
        try:
            cached = json.loads(cache.read_text(encoding="utf-8"))
            models = [m for m in cached.get("models") or [] if is_free(str(m))]
            if models and (cache.stat().st_mtime + 600) > _now():
                return models
        except (OSError, ValueError):
            pass
    try:
        done = subprocess.run(
            [binary, "models"],
            capture_output=True, text=True, timeout=15, env=env, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    models = parse_models_output(done.stdout + "\n" + done.stderr)
    if not models:
        try:
            done = subprocess.run(
                [binary, "models", "opencode"],
                capture_output=True, text=True, timeout=15, env=env, check=False,
            )
            models = parse_models_output(done.stdout + "\n" + done.stderr)
        except (OSError, subprocess.TimeoutExpired):
            pass
    if cache is not None and models:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"models": models}), encoding="utf-8")
        except OSError:
            pass
    return models


def role_for(*, lead: bool = False, app: bool = False, handoff: bool = False, swarm: bool = False) -> str:
    if app:
        return "app"
    if swarm:
        return "swarm"
    if lead:
        return "lead"
    if handoff:
        return "handoff"
    return "specialist"


def select(role: str, listed: list[str] | None = None) -> str:
    candidates = [m for m in (listed or []) if is_free(m)]
    if not candidates:
        candidates = [m for m in KNOWN_FREE if is_free(m)]
    hints = _PREFER.get(role, _PREFER["specialist"])
    for hint in hints:
        for model in candidates:
            if hint in model:
                return model
    # Last resort: any free opencode model, never a platform/default/proxy one.
    for model in candidates:
        if model.startswith("opencode/") and "aseman" not in model:
            return model
    raise ValueError("no free opencode model available")


def default_binary() -> str:
    return os.environ.get("ASEMAN_OPENCODE_BIN") or "opencode"


# Alias used by older/newer code paths
binary = default_binary
