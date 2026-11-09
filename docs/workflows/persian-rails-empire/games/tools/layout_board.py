#!/usr/bin/env python3
"""Clean board-game layout for Persian Rails — Ticket-to-Ride style spacing.

Keeps geographic order of Iranian cities but spreads the crowded north /
northwest / Caspian corridor so roads read as clean corridors, not spaghetti.

    python3 games/tools/layout_board.py
"""

from __future__ import annotations

import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(
    os.path.join(HERE, "..", "persian-rails", "arena", "persian_rails", "data")
)
APP_MAP = os.path.normpath(os.path.join(HERE, "..", "..", "app", "data", "map"))

# Curated board positions (x, z). Geographic order preserved; NW/Caspian opened up.
# Inspired by real Iran map proportions, tuned for clean rail corridors.
LAYOUT = {
    # Northwest — open diamond around Lake Urmia / Tabriz (on land)
    "urmia": (-7.35, -3.35),
    "tabriz": (-5.55, -4.05),
    "maragheh": (-5.85, -2.65),
    "ardabil": (-3.65, -3.25),
    "zanjan": (-4.25, -1.85),
    # Caspian coast — south of the shoreline so gems sit on land
    "rasht": (-2.55, -2.45),
    "sari": (-0.35, -2.25),
    "gorgan": (1.55, -2.85),
    "bandar_torkaman": (2.55, -3.15),
    # Center spine
    "qazvin": (-2.85, -1.35),
    "tehran": (-1.25, -1.05),
    "semnan": (1.05, -0.85),
    "shahroud": (2.45, -1.65),
    "qom": (-2.05, -0.15),
    "kashan": (-1.35, 1.05),
    "isfahan": (-1.15, 2.35),
    "yazd": (0.85, 2.85),
    # West
    "hamedan": (-4.35, -0.35),
    "kermanshah": (-5.85, 0.15),
    "arak": (-3.15, 0.75),
    "khorramabad": (-4.45, 1.25),
    "ahvaz": (-3.95, 3.15),
    # East — Mashhad corridor with even beads (kept inside land silhouette)
    "sabzevar": (3.65, -1.85),
    "neyshabur": (4.75, -1.75),
    "mashhad": (5.85, -2.05),
    "birjand": (4.65, 1.35),
    "zahedan": (5.75, 3.85),
    # South
    "shiraz": (-0.75, 4.35),
    "bushehr": (-2.25, 4.85),
    "kerman": (2.95, 3.55),
    "bam": (4.15, 4.45),
    "bandar_abbas": (2.25, 6.15),
    "chabahar": (5.55, 7.15),
}

# Routes that create spaghetti in the circled north corridor.
DROP_ROUTES = {
    "r40",  # duplicate Tehran–Semnan
    "r49",  # duplicate Kashan–Isfahan
    "r41",  # Zanjan–Rasht (triangles over Qazvin)
    "r39",  # Gorgan–Shahroud (too short for 3 cars)
    "r47",  # Semnan–Sabzevar long diagonal crossing the east spine
    "r42",  # Ardabil–Rasht coastal clutter
}

ADD_ROUTES = [
    {
        "id": "r51",
        "from": "yazd",
        "to": "birjand",
        "color": "green",
        "terrain": "desert",
        "gameType": "scenario_proposed",
        "notes": "مسیر مفهومی بازی؛ تا تأیید منبع رسمی به‌عنوان سناریویی علامت خورده است.",
    },
]


def route_length(dist: float) -> int:
    """Segment count from board distance — even, readable cars."""
    if dist < 1.15:
        return 1
    if dist < 1.85:
        return 2
    if dist < 2.75:
        return 3
    if dist < 3.7:
        return 4
    if dist < 4.7:
        return 5
    return 6


def main() -> None:
    cpath = os.path.join(DATA, "cities.json")
    cities = json.load(open(cpath, encoding="utf-8"))
    by_id = {c["id"]: c for c in cities}

    for cid, (x, z) in LAYOUT.items():
        if cid not in by_id:
            continue
        by_id[cid]["x"] = round(x, 3)
        by_id[cid]["z"] = round(z, 3)

    with open(cpath, "w", encoding="utf-8") as f:
        json.dump(cities, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", cpath)

    app_c = os.path.join(APP_MAP, "cities.json")
    if os.path.isfile(app_c):
        with open(app_c, "w", encoding="utf-8") as f:
            json.dump(cities, f, ensure_ascii=False, indent=2)
            f.write("\n")

    rpath = os.path.join(DATA, "routes.json")
    routes = json.load(open(rpath, encoding="utf-8"))
    kept = []
    dropped = []
    have = set()
    for r in routes:
        if r["id"] in DROP_ROUTES:
            dropped.append(r["id"])
            continue
        a, b = by_id[r["from"]], by_id[r["to"]]
        d = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
        r["length"] = route_length(d)
        kept.append(r)
        have.add(r["id"])
    for r in ADD_ROUTES:
        if r["id"] in have:
            continue
        a, b = by_id[r["from"]], by_id[r["to"]]
        d = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
        nr = dict(r)
        nr["length"] = route_length(d)
        kept.append(nr)
    with open(rpath, "w", encoding="utf-8") as f:
        json.dump(kept, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", rpath, "kept", len(kept), "dropped", dropped)

    app_r = os.path.join(APP_MAP, "routes.json")
    if os.path.isfile(app_r):
        with open(app_r, "w", encoding="utf-8") as f:
            json.dump(kept, f, ensure_ascii=False, indent=2)
            f.write("\n")

    # Sanity: min spacing + route segment sizes
    ids = [(c["id"], c["x"], c["z"]) for c in cities]
    mind = 999.0
    pair = None
    for i, (a, x1, z1) in enumerate(ids):
        for b, x2, z2 in ids[i + 1 :]:
            d = math.hypot(x1 - x2, z1 - z2)
            if d < mind:
                mind, pair = d, (a, b, round(d, 3))
    print("closest cities", pair)
    short = []
    for r in kept:
        a, b = by_id[r["from"]], by_id[r["to"]]
        d = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
        seg = d / max(r["length"], 1)
        if seg < 0.55:
            short.append((r["id"], r["from"], r["to"], round(d, 2), r["length"], round(seg, 2)))
    print("cramped segments", short or "none")


if __name__ == "__main__":
    main()
