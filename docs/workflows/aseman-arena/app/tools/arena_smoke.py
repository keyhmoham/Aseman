#!/usr/bin/env python3
"""Proves a running Arena works end to end, as a system player (hidden
from the leaderboards): the store lists both official games and serves
their packs; a garage opens with its 3D layout; a private room is opened,
a match is played and its result is rated; the room is closed again.

    arena_smoke.py http://127.0.0.1:8080            # prints arena-smoke-ok
    arena_smoke.py http://127.0.0.1:8080 --forge    # also: the Forge agent builds a game (forge-demo-ok)
"""

import json
import sys
import time
import urllib.error
import urllib.request

USER = {"X-Aseman-User": "system:smoke", "X-Aseman-User-Handle": "arena-smoke"}


def call(base, method, path, body=None, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    h = dict(USER, **({"Content-Type": "application/json"} if data else {}))
    req = urllib.request.Request(base.rstrip("/") + "/" + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = r.read()
            return out if raw else json.loads(out or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit("arena-smoke-failed: %s %s → %d %s" % (method, path, e.code, e.read()[:300].decode(errors="replace")))


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
    games = {g["slug"]: g for g in call(base, "GET", "api/store")["games"]}
    for slug in ("arena-chess", "city-strike"):
        if slug not in games:
            sys.exit("arena-smoke-failed: %s is not in the store" % slug)
        g = games[slug]
        pack = call(base, "GET", "games/%s/%s" % (slug, g["launch"]["pack"].split("/")[-1].split("?")[0]), raw=True)
        if pack[:4] != b"GDPC":
            sys.exit("arena-smoke-failed: %s's pack is not a Godot pack" % slug)
    garage = call(base, "GET", "api/garage")
    if len(garage["layout"]["items"]) < 8:
        sys.exit("arena-smoke-failed: the garage has no furniture")
    room = call(base, "POST", "api/rooms", {"name": "Smoke test", "game": "arena-chess", "theme": "arena", "visibility": "private", "settings": {"level": 2}})
    out = call(base, "POST", "api/rooms/%s/matches" % room["id"], {})
    if out["launch"]["params"].get("level") != 2 or not out["launch"]["pack"]:
        sys.exit("arena-smoke-failed: the match did not launch with the room's settings")
    res = call(base, "POST", "api/matches/%s/result" % out["match"]["id"],
               {"token": out["match"]["token"], "type": "result", "game": "arena-chess", "outcome": "loss", "reason": "resignation", "score": 20, "duration_s": 0, "level": 2})
    if "rating" not in res:
        sys.exit("arena-smoke-failed: the result was not rated")
    call(base, "DELETE", "api/rooms/" + room["id"])
    print("arena-smoke-ok: %d games, garage of %d models, a rated match (%+d)" % (len(games), len(garage["layout"]["items"]), res["rating_change"]))
    if "--forge" in sys.argv:
        p = call(base, "POST", "api/forge", {"title": "Orbit Dodge", "genre": "arcade",
                 "brief": "A small 3D arcade game: steer a ship around a planet and dodge three AI hunter drones that predict your path; survive 90 seconds to win. Keep it simple and finish it."})
        pid = p["project"]["id"]
        deadline = time.time() + 55 * 60
        while time.time() < deadline:
            time.sleep(20)
            st = call(base, "GET", "api/forge/" + pid)
            if st["project"]["status"] in ("ready", "published"):
                print("forge-demo-ok: %s built %s" % (pid, st["project"]["slug"]))
                return 0
            last = st["messages"][-1]
            if last["state"] == "failed":
                sys.exit("forge-demo-failed: " + last["text"][:300])
            if last["state"] == "done" and last["role"] == "agent" and st["project"]["status"] == "drafting":
                call(base, "POST", "api/forge/%s/messages" % pid, {"text": "Sounds good — please build it now, test it and submit it."})
        sys.exit("forge-demo-failed: the game was not submitted in time")
    return 0


if __name__ == "__main__":
    sys.exit(main())
