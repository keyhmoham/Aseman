#!/usr/bin/env python3
"""Starts every iran-mcp server in the catalog, asks it for its tools (no site
is contacted) and checks that the tools the catalog routes to still exist.

    python scripts/check_services.py            # exit 1 if a routed tool is missing
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from peyda.catalog import Catalog  # noqa: E402
from peyda.gateway import Connection, default_launcher  # noqa: E402


async def check(service, launch, sem):
    async with sem:
        try:
            conn = Connection(service, launch(service), 90, 30)
            await conn.ready()
        except Exception as e:  # noqa: BLE001
            return service.id, f"does not start: {type(e).__name__}: {e}"[:160], []
        try:
            missing = [t.name for t in service.tools if t.name not in conn.tools]
            extra = [n for n in (service.geocode, service.resolve) if n and n not in conn.tools]
            return service.id, "", missing + extra
        finally:
            await conn.close()


async def main() -> int:
    catalog = Catalog.load()
    launch = default_launcher()
    sem = asyncio.Semaphore(8)
    results = await asyncio.gather(*(check(s, launch, sem) for s in catalog.services.values()))
    bad = 0
    for sid, error, missing in sorted(results):
        if error or missing:
            bad += 1
            print(f"  FAIL {sid}: {error or 'missing tools ' + ', '.join(missing)}")
    print(f"services: {len(results) - bad} of {len(results)} start and offer every tool Peyda routes to")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
