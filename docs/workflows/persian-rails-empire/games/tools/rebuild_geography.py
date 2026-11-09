#!/usr/bin/env python3
"""Rebuild Iran board geography from OSM Nominatim (ODbL).

Fits Iran + Caspian (north) + Persian Gulf / Oman (south) into the board
with a linear lon/lat → xz transform, Chaikin-smoothed coastlines, and
city positions from real coordinates with light spacing.

    python3 games/tools/rebuild_geography.py
"""

from __future__ import annotations

import json
import math
import os
import ssl
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(
    os.path.join(HERE, "..", "persian-rails", "arena", "persian_rails", "data")
)

# Geographic window that includes southern Caspian + Persian Gulf shelf.
LON0, LON1 = 44.0, 63.4
LAT0, LAT1 = 24.35, 44.2  # south … north (enough Caspian oval)
# Board target (leave wood-frame margin; parchment ~18×20).
X0, X1 = -7.85, 7.85
Z0, Z1 = -9.15, 8.85  # north … south  (z grows southward)

UA = "persian-rails-empire/1.5 (geography rebuild; contact: aseman)"

CITY_LL = {
    "tabriz": (38.0962, 46.2738),
    "maragheh": (37.3890, 46.2370),
    "zanjan": (36.6736, 48.4787),
    "urmia": (37.5527, 45.0761),
    "ardabil": (38.2498, 48.2933),
    "rasht": (37.2808, 49.5832),
    "sari": (36.5633, 53.0601),
    "gorgan": (36.8427, 54.4350),
    "bandar_torkaman": (36.9019, 54.0729),
    "tehran": (35.6892, 51.3890),
    "qazvin": (36.2688, 50.0041),
    "qom": (34.6416, 50.8746),
    "kashan": (33.9850, 51.4100),
    "isfahan": (32.6539, 51.6660),
    "yazd": (31.8974, 54.3569),
    "semnan": (35.5769, 53.3920),
    "shahroud": (36.4182, 54.9763),
    "kermanshah": (34.3142, 47.0650),
    "hamedan": (34.7983, 48.5146),
    "arak": (34.0917, 49.6892),
    "khorramabad": (33.4878, 48.3558),
    "ahvaz": (31.3183, 48.6706),
    "mashhad": (36.2605, 59.6168),
    "neyshabur": (36.2133, 58.7958),
    "sabzevar": (36.2126, 57.6819),
    "birjand": (32.8649, 59.2262),
    "zahedan": (29.4963, 60.8629),
    "shiraz": (29.5918, 52.5837),
    "bushehr": (28.9234, 50.8203),
    "bandar_abbas": (27.1865, 56.2808),
    "kerman": (30.2832, 57.0788),
    "bam": (29.1060, 58.3570),
    "chabahar": (25.2919, 60.6430),
}


def lonlat_to_xz(lon: float, lat: float) -> tuple[float, float]:
    x = X0 + (lon - LON0) / (LON1 - LON0) * (X1 - X0)
    # High lat → north → negative z
    z = Z0 + (LAT1 - lat) / (LAT1 - LAT0) * (Z1 - Z0)
    return x, z


def transform_formula() -> dict:
    # x = sx*lon + ox ; z = sz*lat + oz
    sx = (X1 - X0) / (LON1 - LON0)
    ox = X0 - sx * LON0
    sz = -(Z1 - Z0) / (LAT1 - LAT0)
    oz = Z0 - sz * LAT1
    return {
        "x": "%.6f*lon + %.6f" % (sx, ox),
        "z": "%.6f*lat + %.6f" % (sz, oz),
        "lon0": LON0,
        "lon1": LON1,
        "lat0": LAT0,
        "lat1": LAT1,
    }


def fetch_nominatim(query: str) -> dict:
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
        {"q": query, "format": "json", "polygon_geojson": 1, "limit": 1}
    )
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=90, context=ctx) as r:
        data = json.loads(r.read().decode())
    if not data or "geojson" not in data[0]:
        raise RuntimeError("no geojson for %s" % query)
    time.sleep(1.05)
    return data[0]["geojson"]


def rings_from_geojson(g: dict) -> list[list[tuple[float, float]]]:
    t = g.get("type")
    c = g.get("coordinates")
    rings: list[list[tuple[float, float]]] = []
    if t == "Polygon":
        rings.append([(float(p[0]), float(p[1])) for p in c[0]])
    elif t == "MultiPolygon":
        for poly in c:
            rings.append([(float(p[0]), float(p[1])) for p in poly[0]])
        rings.sort(key=lambda r: abs(_area(r)), reverse=True)
    else:
        raise RuntimeError("unsupported geojson type %s" % t)
    return rings


def _area(ring: list[tuple[float, float]]) -> float:
    a = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        a += x1 * y2 - x2 * y1
    return a * 0.5


def douglas_peucker(pts: list[tuple[float, float]], eps: float) -> list[tuple[float, float]]:
    if len(pts) < 3:
        return pts

    def perp(p, a, b):
        ax, ay = a
        bx, by = b
        px, py = p
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))

    def rec(seg):
        if len(seg) < 3:
            return seg
        a, b = seg[0], seg[-1]
        idx, dmax = 0, 0.0
        for i in range(1, len(seg) - 1):
            d = perp(seg[i], a, b)
            if d > dmax:
                idx, dmax = i, d
        if dmax > eps:
            return rec(seg[: idx + 1])[:-1] + rec(seg[idx:])
        return [a, b]

    closed = pts[0] == pts[-1]
    core = pts[:-1] if closed else list(pts)
    out = rec(core)
    if closed:
        out.append(out[0])
    return out


def chaikin(pts: list[tuple[float, float]], rounds: int = 2) -> list[tuple[float, float]]:
    """Corner-cutting smoother — keeps overall shape, kills jagged DP edges."""
    if len(pts) < 3:
        return pts
    closed = pts[0] == pts[-1]
    cur = pts[:-1] if closed else list(pts)
    for _ in range(rounds):
        nxt = []
        n = len(cur)
        for i in range(n):
            p = cur[i]
            q = cur[(i + 1) % n]
            nxt.append((0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]))
            nxt.append((0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1]))
        cur = nxt
    if closed:
        cur.append(cur[0])
    return cur


def clip_lonlat(
    ring: list[tuple[float, float]],
    lon_min: float,
    lon_max: float,
    lat_min: float,
    lat_max: float,
) -> list[tuple[float, float]]:
    """Sutherland–Hodgman in lon/lat (degrees)."""

    def clip_edge(pts, inside, intersect):
        if not pts:
            return []
        out = []
        prev = pts[-1]
        prev_in = inside(prev)
        for cur in pts:
            cur_in = inside(cur)
            if cur_in:
                if not prev_in:
                    out.append(intersect(prev, cur))
                out.append(cur)
            elif prev_in:
                out.append(intersect(prev, cur))
            prev, prev_in = cur, cur_in
        return out

    def ix(a, b, lon):
        ax, ay = a
        bx, by = b
        if bx == ax:
            return (lon, ay)
        t = (lon - ax) / (bx - ax)
        return (lon, ay + t * (by - ay))

    def iy(a, b, lat):
        ax, ay = a
        bx, by = b
        if by == ay:
            return (ax, lat)
        t = (lat - ay) / (by - ay)
        return (ax + t * (bx - ax), lat)

    poly = list(ring)
    if poly and poly[0] == poly[-1]:
        poly = poly[:-1]
    poly = clip_edge(poly, lambda p: p[0] >= lon_min, lambda a, b: ix(a, b, lon_min))
    poly = clip_edge(poly, lambda p: p[0] <= lon_max, lambda a, b: ix(a, b, lon_max))
    poly = clip_edge(poly, lambda p: p[1] >= lat_min, lambda a, b: iy(a, b, lat_min))
    poly = clip_edge(poly, lambda p: p[1] <= lat_max, lambda a, b: iy(a, b, lat_max))
    return poly


def densify_cut_edges(ring: list[tuple[float, float]], step_deg: float = 0.35) -> list[tuple[float, float]]:
    """Break long axis-aligned clip edges into short segments so Chaikin rounds them."""
    if len(ring) < 2:
        return ring
    out = []
    n = len(ring)
    for i in range(n):
        a = ring[i]
        b = ring[(i + 1) % n]
        out.append(a)
        dlon = b[0] - a[0]
        dlat = b[1] - a[1]
        length = math.hypot(dlon, dlat)
        axis = abs(dlon) < 1e-9 or abs(dlat) < 1e-9
        if axis and length > step_deg * 1.5:
            steps = max(2, int(length / step_deg))
            for k in range(1, steps):
                t = k / float(steps)
                out.append((a[0] + dlon * t, a[1] + dlat * t))
    return out


def simplify_smooth(
    ring_ll: list[tuple[float, float]],
    max_pts: int,
    eps_deg: float,
    chaikin_rounds: int = 2,
) -> list[list[float]]:
    pts = list(ring_ll)
    if len(pts) >= 2 and pts[0] != pts[-1]:
        pts.append(pts[0])
    simp = douglas_peucker(pts, eps_deg)
    if len(simp) < 4:
        return []
    # Drop closing point for densify/chaikin cycle
    if simp[0] == simp[-1]:
        simp = simp[:-1]
    simp = densify_cut_edges(simp, step_deg=max(eps_deg * 4, 0.25))
    simp.append(simp[0])
    smooth = chaikin(simp, rounds=chaikin_rounds)
    if smooth[0] == smooth[-1]:
        smooth = smooth[:-1]
    # Resample to max_pts
    if len(smooth) > max_pts:
        step = len(smooth) / float(max_pts)
        spaced = []
        i = 0.0
        while int(i) < len(smooth) and len(spaced) < max_pts:
            spaced.append(smooth[int(i)])
            i += step
        smooth = spaced
    # Transform
    out = []
    for lon, lat in smooth:
        x, z = lonlat_to_xz(lon, lat)
        out.append([round(x, 3), round(z, 3)])
    # Dedupe near-duplicates
    cleaned = [out[0]]
    for p in out[1:]:
        q = cleaned[-1]
        if (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 >= 0.0025:
            cleaned.append(p)
    return cleaned


def round_bbox_edges(
    ring_ll: list[tuple[float, float]],
    lon_min: float,
    lon_max: float,
    lat_min: float,
    lat_max: float,
    bulge: float = 0.55,
) -> list[tuple[float, float]]:
    """Replace long flat clip edges with gentle arcs so seas read as ovals, not boxes."""
    if len(ring_ll) < 6:
        return ring_ll
    pts = list(ring_ll)
    if pts[0] == pts[-1]:
        pts = pts[:-1]
    out: list[tuple[float, float]] = []
    n = len(pts)
    tol = 0.04

    def arc_between(a, b, toward_out: str):
        """Insert curved midpoints between a and b."""
        ax, ay = a
        bx, by = b
        dist = math.hypot(bx - ax, by - ay)
        steps = max(3, int(dist / 0.28))
        mids = []
        for k in range(1, steps):
            t = k / float(steps)
            x = ax + (bx - ax) * t
            y = ay + (by - ay) * t
            # bump outward from the bbox interior
            s = math.sin(math.pi * t) * bulge
            if toward_out == "north":
                y += s
            elif toward_out == "south":
                y -= s
            elif toward_out == "east":
                x += s * 0.7
            elif toward_out == "west":
                x -= s * 0.7
            mids.append((x, y))
        return mids

    for i in range(n):
        a = pts[i]
        b = pts[(i + 1) % n]
        out.append(a)
        dlon = abs(b[0] - a[0])
        dlat = abs(b[1] - a[1])
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        if length < 0.8:
            continue
        if dlat < tol and abs(a[1] - lat_max) < tol and abs(b[1] - lat_max) < tol:
            out.extend(arc_between(a, b, "north"))
        elif dlat < tol and abs(a[1] - lat_min) < tol and abs(b[1] - lat_min) < tol:
            out.extend(arc_between(a, b, "south"))
        elif dlon < tol and abs(a[0] - lon_max) < tol and abs(b[0] - lon_max) < tol:
            out.extend(arc_between(a, b, "east"))
        elif dlon < tol and abs(a[0] - lon_min) < tol and abs(b[0] - lon_min) < tol:
            out.extend(arc_between(a, b, "west"))
    return out


def pick_ring(
    geo: dict,
    lon_min,
    lon_max,
    lat_min,
    lat_max,
    max_pts,
    eps,
    rounds=2,
    min_pts=10,
    round_clip=True,
    bulge=0.55,
):
    best = None
    best_area = 0.0
    for ring in rings_from_geojson(geo)[:5]:
        clipped = clip_lonlat(ring, lon_min, lon_max, lat_min, lat_max)
        if len(clipped) < 6:
            continue
        if round_clip:
            clipped = round_bbox_edges(clipped, lon_min, lon_max, lat_min, lat_max, bulge=bulge)
        outline = simplify_smooth(clipped, max_pts=max_pts, eps_deg=eps, chaikin_rounds=rounds)
        if len(outline) < min_pts:
            continue
        area = abs(_area([(p[0], p[1]) for p in outline]))
        if area > best_area:
            best_area = area
            best = outline
    return best


def space_cities(positions: dict[str, tuple[float, float]], min_dist: float = 1.02) -> dict[str, tuple[float, float]]:
    """Repel cities that sit too close while keeping geographic order."""
    dense = {
        "tabriz", "maragheh", "urmia", "ardabil", "zanjan",
        "rasht", "qazvin", "gorgan", "bandar_torkaman", "sari",
        "neyshabur", "sabzevar", "mashhad",
    }
    ids = list(positions.keys())
    pts = {k: [positions[k][0], positions[k][1]] for k in ids}
    targets = {k: positions[k] for k in ids}
    for _ in range(110):
        forces = {k: [0.0, 0.0] for k in ids}
        for i, a in enumerate(ids):
            for b in ids[i + 1 :]:
                dx = pts[a][0] - pts[b][0]
                dz = pts[a][1] - pts[b][1]
                d = math.hypot(dx, dz) or 0.001
                need = min_dist * (1.18 if (a in dense and b in dense) else 1.0)
                if d < need:
                    push = (need - d) * 0.28
                    ux, uz = dx / d, dz / d
                    forces[a][0] += ux * push
                    forces[a][1] += uz * push
                    forces[b][0] -= ux * push
                    forces[b][1] -= uz * push
        for k in ids:
            tx, tz = targets[k]
            forces[k][0] += (tx - pts[k][0]) * 0.07
            forces[k][1] += (tz - pts[k][1]) * 0.07
            pts[k][0] = max(X0 + 0.35, min(X1 - 0.35, pts[k][0] + forces[k][0]))
            pts[k][1] = max(Z0 + 0.4, min(Z1 - 0.5, pts[k][1] + forces[k][1]))
    return {k: (round(pts[k][0], 3), round(pts[k][1], 3)) for k in ids}


def preview_png(geo: dict, cities: list, path: str) -> None:
    from PIL import Image, ImageDraw, ImageFont

    W, H = 900, 1000
    img = Image.new("RGB", (W, H), (236, 228, 210))
    draw = ImageDraw.Draw(img, "RGBA")

    def to_px(x, z):
        # north (neg z) at top
        px = int((x - X0) / (X1 - X0) * (W - 40) + 20)
        py = int((z - Z0) / (Z1 - Z0) * (H - 40) + 20)
        return px, py

    def poly(pts, fill, outline):
        if len(pts) < 3:
            return
        xy = [to_px(p[0], p[1]) for p in pts]
        draw.polygon(xy, fill=fill, outline=outline)

    poly(geo["iran_outline"], (232, 196, 130, 255), (59, 36, 24, 255))
    for s in geo.get("seas", []):
        c = s["color"].lstrip("#")
        rgb = tuple(int(c[i : i + 2], 16) for i in (0, 2, 4))
        poly(s["outline"], rgb + (230,), (20, 60, 90, 255))
    for s in geo.get("lakes", []):
        c = s["color"].lstrip("#")
        rgb = tuple(int(c[i : i + 2], 16) for i in (0, 2, 4))
        poly(s["outline"], rgb + (240,), (20, 60, 90, 255))
    for c in cities:
        px, py = to_px(c["x"], c["z"])
        draw.ellipse((px - 4, py - 4, px + 4, py + 4), fill=(201, 162, 39), outline=(40, 20, 10))
    img.save(path)
    print("preview", path)


def main() -> None:
    print("fetch Iran…")
    iran_g = fetch_nominatim("Iran")
    print("fetch Caspian Sea…")
    caspian_g = fetch_nominatim("Caspian Sea")
    print("fetch Persian Gulf…")
    gulf_g = fetch_nominatim("Persian Gulf")
    print("fetch Gulf of Oman…")
    oman_g = fetch_nominatim("Gulf of Oman")
    print("fetch Lake Urmia…")
    urmia_g = fetch_nominatim("Lake Urmia Iran")
    print("fetch Lake Namak…")
    namak_g = fetch_nominatim("Lake Namak Iran")

    # Iran: full country in window — keep clip edges sharp (real border, not rounded).
    iran = pick_ring(
        iran_g, LON0, LON1, LAT0, 39.95, max_pts=180, eps=0.022, rounds=4, min_pts=28, round_clip=False
    )
    if not iran:
        raise RuntimeError("failed Iran outline")
    print("iran pts", len(iran))

    # Caspian: elongated oval — bulge the northern clip so it isn't a flat bar.
    caspian = pick_ring(
        caspian_g,
        lon_min=46.55,
        lon_max=54.35,
        lat_min=36.45,
        lat_max=44.15,
        max_pts=96,
        eps=0.04,
        rounds=3,
        min_pts=16,
        round_clip=True,
        bulge=0.85,
    )
    print("caspian", None if not caspian else len(caspian))

    gulf = pick_ring(
        gulf_g,
        lon_min=47.6,
        lon_max=56.6,
        lat_min=24.45,
        lat_max=30.55,
        max_pts=100,
        eps=0.035,
        rounds=3,
        min_pts=16,
        round_clip=True,
        bulge=0.45,
    )
    print("persian_gulf", None if not gulf else len(gulf))

    oman = pick_ring(
        oman_g,
        lon_min=56.2,
        lon_max=62.8,
        lat_min=24.45,
        lat_max=26.2,
        max_pts=56,
        eps=0.035,
        rounds=3,
        min_pts=10,
        round_clip=True,
        bulge=0.35,
    )
    print("oman_gulf", None if not oman else len(oman))

    urmia = pick_ring(
        urmia_g, 44.8, 46.0, 37.05, 38.35, max_pts=44, eps=0.007, rounds=3, min_pts=8, round_clip=False
    )
    namak = pick_ring(
        namak_g, 51.4, 52.3, 34.25, 34.9, max_pts=32, eps=0.005, rounds=3, min_pts=6, round_clip=False
    )
    print("urmia", None if not urmia else len(urmia), "namak", None if not namak else len(namak))

    seas = []
    if caspian:
        seas.append({"id": "caspian", "name_fa": "دریای خزر", "kind": "sea", "color": "#1a7399", "outline": caspian})
    if gulf:
        seas.append({"id": "persian_gulf", "name_fa": "خلیج فارس", "kind": "sea", "color": "#1d7aa0", "outline": gulf})
    if oman:
        seas.append({"id": "oman_gulf", "name_fa": "دریای عمان", "kind": "sea", "color": "#1a7296", "outline": oman})

    lakes = []
    if urmia:
        lakes.append({"id": "urmia", "name_fa": "دریاچه ارومیه", "kind": "lake", "color": "#2489ad", "outline": urmia})
    if namak:
        lakes.append({"id": "namak", "name_fa": "دریاچه نمک", "kind": "lake", "color": "#3497b4", "outline": namak})

    geo = {
        "source": "OSM Nominatim full Iran border + Caspian/Persian Gulf/Oman polygons (ODbL), Chaikin-smoothed.",
        "transform": transform_formula(),
        "iran_outline": iran,
        "seas": seas,
        "lakes": lakes,
    }
    gpath = os.path.join(DATA, "geography.json")
    with open(gpath, "w", encoding="utf-8") as f:
        json.dump(geo, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote", gpath)

    wpath = os.path.join(DATA, "waters.json")
    with open(wpath, "w", encoding="utf-8") as f:
        json.dump({"source": geo["source"], "seas": seas, "lakes": lakes}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote", wpath)

    raw = {cid: lonlat_to_xz(ll[1], ll[0]) for cid, ll in CITY_LL.items()}
    # Nudge coastal ports slightly inland so gems sit clearly on land (seas under land).
    inland_nudge = {
        "rasht": (0.0, 0.22),
        "sari": (0.0, 0.18),
        "gorgan": (0.05, 0.18),
        "bandar_torkaman": (0.0, 0.25),
        "bushehr": (0.15, -0.2),
        "bandar_abbas": (0.0, -0.25),
        "chabahar": (-0.15, -0.3),
    }
    for cid, (dx, dz) in inland_nudge.items():
        if cid in raw:
            raw[cid] = (raw[cid][0] + dx, raw[cid][1] + dz)
    spaced = space_cities(raw, min_dist=1.05)
    cpath = os.path.join(DATA, "cities.json")
    cities = json.load(open(cpath, encoding="utf-8"))
    for c in cities:
        cid = c["id"]
        if cid in spaced:
            c["x"], c["z"] = spaced[cid]
            lat, lon = CITY_LL[cid]
            c["lat"] = round(lat, 4)
            c["lon"] = round(lon, 4)
    with open(cpath, "w", encoding="utf-8") as f:
        json.dump(cities, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", cpath)

    app_cities = os.path.normpath(os.path.join(HERE, "..", "..", "app", "data", "map", "cities.json"))
    if os.path.isfile(app_cities):
        with open(app_cities, "w", encoding="utf-8") as f:
            json.dump(cities, f, ensure_ascii=False, indent=2)
            f.write("\n")

    preview_png(geo, cities, "/tmp/pr_geo_preview.png")

    # Quick shape checks
    for s in seas:
        o = s["outline"]
        xs = [p[0] for p in o]
        zs = [p[1] for p in o]
        print(s["id"], "bbox x", round(min(xs), 2), round(max(xs), 2), "z", round(min(zs), 2), round(max(zs), 2), "aspect_h/w", round((max(zs) - min(zs)) / max(0.01, max(xs) - min(xs)), 2))


if __name__ == "__main__":
    main()
