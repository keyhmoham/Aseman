#!/usr/bin/env python3
"""Installs the Google Maps Scraper Kit's engine for Peyda's Google Maps service,
idempotently:

    python scripts/install_gmaps.py [--no-start]

1. the kit's source at the commit peyda/gmaps.py pins, from GitHub's archive
   (codeload.github.com), into PEYDA_GMAPS_KIT (/workspace/.gmaps-kit); a kit
   already at that commit is kept, along with its downloaded Chrome and jobs;
2. `scripts/engine.py start`, which downloads the pinned Chrome for Testing
   headless shell once (storage.googleapis.com, checked against its SHA-256)
   when the computer has no Chrome, and starts the engine on PEYDA_GMAPS_PORT;
3. checks the engine answers, then stops it (start.sh starts it with Peyda).

The kit runs unmodified as its own process; Peyda talks to it over its local
HTTP API only. It needs nothing beyond the Python standard library.
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from peyda.gmaps import KIT_COMMIT, KIT_REPO, Engine, EngineError, settings  # noqa: E402

MARK = ".peyda-commit"


def fetch(kit: Path) -> None:
    if (kit / MARK).is_file() and (kit / MARK).read_text().strip() == KIT_COMMIT and (kit / "scripts" / "engine.py").is_file():
        print(f"google maps kit: {KIT_COMMIT[:12]} already in {kit}")
        return
    url = f"https://codeload.github.com/{KIT_REPO}/tar.gz/{KIT_COMMIT}"
    print(f"google maps kit: downloading {url}")
    with urllib.request.urlopen(url, timeout=120) as r:  # honours HTTPS_PROXY
        data = r.read()
    kit.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=kit.parent) as tmp:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            for m in tar.getmembers():  # no absolute paths, no "..", no links out
                if m.name.startswith("/") or ".." in Path(m.name).parts or m.issym() or m.islnk() or m.isdev():
                    raise SystemExit(f"google maps kit: refusing archive member {m.name!r}")
            tar.extractall(tmp)
        (top,) = [p for p in Path(tmp).iterdir() if p.is_dir()]
        keep = kit / ".engine"  # an earlier install's Chrome and jobs
        if keep.is_dir():
            shutil.move(str(keep), str(top / ".engine"))
        if kit.exists():
            shutil.rmtree(kit)
        shutil.move(str(top), str(kit))
    (kit / MARK).write_text(KIT_COMMIT + "\n")
    print(f"google maps kit: {KIT_COMMIT[:12]} installed in {kit}")


def main() -> int:
    s = settings()
    kit = Path(s["kit_dir"])
    try:
        fetch(kit)
    except OSError as e:  # urllib's HTTPError and URLError are OSErrors
        print(f"google maps kit: could not download it: {e}. A 403 from the computer's proxy means the "
              "project's network policy refuses codeload.github.com (run the workflow with manage_network=true)")
        return 1
    if "--no-start" in sys.argv:
        print("google maps engine ready (not started)")
        return 0
    engine = Engine.from_env()
    engine.python = sys.executable if s["python"] == "python3" else s["python"]
    try:
        engine.ensure(wait=600)  # the first start downloads Chrome (~100 MB)
    except EngineError as e:
        print(f"google maps engine: {e}")
        log = kit / ".engine" / "engine.log"
        if log.is_file():
            print("--- engine log tail\n" + "\n".join(log.read_text(errors="replace").splitlines()[-20:]))
        return 1
    print(f"google maps engine answers on {engine.base_url}")
    env = dict(os.environ, SCRAPER_PORT=str(s["port"]))
    subprocess.run([engine.python, str(kit / "scripts" / "engine.py"), "stop"], cwd=kit, env=env,
                   stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    print("google maps engine ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
