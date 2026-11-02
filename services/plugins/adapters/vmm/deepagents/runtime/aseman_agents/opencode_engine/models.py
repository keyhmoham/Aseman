"""Free models only: OpenCode's own gateway, never the platform LLM proxy."""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path

# Anything that isn't an ``opencode/…`` or ``opencode-go/…`` id that is free
# (the id says so, the cost is zero, or it comes from the OpenCode free list)
# is rejected by the CLI and engine. Platform ids like ``aseman/default`` must
# never be used here (and the programmer path uses them).
FREE_MARKERS = ("-free", "free", "big-pickle")
# Some OpenCode builds bundle specific ids even if verbose listing is empty.
BUNDLED_FREE = frozenset({
    "opencode/big-pickle", "opencode/beam-free",
    "opencode-go/beam-free", "opencode-go/iceman-contributor-free",
})

# Preference order when `opencode models` cannot be read. Anonymous free tier
# first; with Go auth the engine prefers the ``opencode-go/`` variants below.
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
# Models on the Go gateway that are free/contributor or cheap flash variants.
# Anonymous ``opencode/X-free`` ids do not always exist as ``opencode-go/X-free``;
# use this list (and the live ``opencode models`` output) instead of remapping.
KNOWN_FREE_GO: tuple[str, ...] = (
    "opencode-go/beam-free",
    "opencode-go/iceman-contributor-free",
    "opencode-go/glm-5.3-flash",
    "opencode-go/deepseek-v4.1-flash",
    "opencode-go/mimo-v2.5",
    "opencode-go/claude-haiku-5-5",
)

# Substrings, best first, for the kind of work. Lead/handoff planning turns
# reason better on DeepSeek; app building is tuned for Flint.
_PREFER: dict[str, tuple[str, ...]] = {
    "lead": ("deepseek", "glm", "flint", "nemotron", "beam", "big-pickle", "flash"),
    "swarm": ("deepseek", "flint", "nemotron", "beam", "glm", "flash", "big-pickle"),
    "app": ("flint", "code", "mimo", "nemotron", "beam", "deepseek", "flash"),
    "handoff": ("deepseek", "flint", "nemotron", "beam", "glm", "flash", "mini", "mimo"),
    "specialist": ("deepseek", "flint", "nemotron", "beam", "glm", "flash", "mini", "mimo"),
}
# With Go auth, prefer free/contributor Go models before metered flash ones.
_PREFER_GO: dict[str, tuple[str, ...]] = {
    "lead": ("beam", "iceman", "glm", "flash", "haiku", "deepseek", "mimo"),
    "swarm": ("beam", "iceman", "glm", "flash", "deepseek", "mimo", "haiku"),
    "app": ("beam", "iceman", "mimo", "glm", "flash", "deepseek", "haiku"),
    "handoff": ("beam", "iceman", "glm", "flash", "deepseek", "mini", "mimo", "haiku"),
    "specialist": ("beam", "iceman", "glm", "flash", "deepseek", "mini", "mimo", "haiku"),
}

_ID = re.compile(r"opencode(?:-go)?/[A-Za-z0-9._+-]+")
_COST = re.compile(r"([0-9]*\.?[0-9]+)\s*/\s*([0-9]*\.?[0-9]+)")


def is_opencode_model(model: str) -> bool:
    """Whether this is OpenCode's own gateway (anonymous or Go), not Aseman."""
    mid = (model or "").strip()
    if not mid or "aseman" in mid:
        return False
    return mid.startswith("opencode/") or mid.startswith("opencode-go/")


def go_model(model: str) -> str:
    """Map an anonymous ``opencode/…`` id onto the Go gateway equivalent."""
    mid = (model or "").strip()
    if mid.startswith("opencode-go/"):
        return mid
    if mid.startswith("opencode/"):
        return "opencode-go/" + mid.split("/", 1)[1]
    return mid


def is_free(model: str, cost: float | None = None) -> bool:
    mid = (model or "").strip()
    if not is_opencode_model(mid):
        return False
    if mid in BUNDLED_FREE or mid in KNOWN_FREE_GO:
        return True
    name = mid.split("/", 1)[-1]
    if any(marker in name for marker in FREE_MARKERS):
        return True
    # Go flash/haiku/mini ids are usable with a Go key even when not named *-free.
    if mid.startswith("opencode-go/") and any(tag in name for tag in ("flash", "haiku", "mini", "iceman")):
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


def fetch_free_models(binary: str, env: dict[str, str], *, cache: Path | None = None,
                      cwd: Path | None = None) -> list[str]:
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
    workdir = str(cwd) if cwd is not None else None
    try:
        # ``--standalone`` lists the models OpenCode itself serves (the free
        # tier); without it the output depends on whatever providers the node
        # happens to have configured.
        done = subprocess.run(
            [binary, "models", "--standalone"],
            capture_output=True, text=True, timeout=15, env=env, cwd=workdir, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    models = parse_models_output(done.stdout + "\n" + done.stderr)
    if not models:
        # Older builds do not know --standalone.
        try:
            done = subprocess.run(
                [binary, "models"],
                capture_output=True, text=True, timeout=15, env=env, cwd=workdir, check=False,
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


def select(role: str, listed: list[str] | None = None, *, prefer_go: bool = False) -> str:
    listed = list(listed or [])
    if prefer_go:
        # Only real Go gateway ids — do not invent opencode-go/<anonymous-free-id>.
        go_listed = [m for m in listed if m.startswith("opencode-go/") and is_free(m)]
        candidates = []
        seen: set[str] = set()
        for pool in (go_listed, list(KNOWN_FREE_GO)):
            for model in pool:
                if model in seen or not is_free(model):
                    continue
                seen.add(model)
                candidates.append(model)
    else:
        candidates = [m for m in listed if is_free(m) and m.startswith("opencode/")]
        if not candidates:
            candidates = [m for m in KNOWN_FREE if is_free(m)]
    hints = (_PREFER_GO if prefer_go else _PREFER).get(role, (_PREFER_GO if prefer_go else _PREFER)["specialist"])
    for hint in hints:
        for model in candidates:
            # Match the model name, not the provider prefix ("code" is in
            # "opencode" and would otherwise match every candidate).
            name = model.split("/", 1)[-1]
            if hint in name:
                return model
    # Last resort: any free OpenCode model, never a platform/default/proxy one.
    for model in candidates:
        if is_opencode_model(model):
            return model
    raise ValueError("no free opencode model available")


def default_binary() -> str:
    return os.environ.get("ASEMAN_OPENCODE_BIN") or "opencode"


# Alias used by older/newer code paths
binary = default_binary
