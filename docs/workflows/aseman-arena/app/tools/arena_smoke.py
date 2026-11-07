#!/usr/bin/env python3
"""Proves a running Arena works end to end, as a system player (hidden
from the leaderboards): the store lists both official games and serves
their packs; a garage opens with its 3D layout; a private room is opened,
a match is played and its result is rated; the room is closed again.

    arena_smoke.py http://127.0.0.1:8080            # prints arena-smoke-ok
    arena_smoke.py http://127.0.0.1:8080 --forge    # also: the Forge agent builds a game (forge-demo-ok)
    arena_smoke.py --stop-old /workspace/apps/aseman-arena
        stops an Arena server left running by an earlier install (its files
        replaced underneath it), so the preview starts the new one
    arena_smoke.py http://127.0.0.1:8080 --wait 240 --games 2 [--agent]
        waits until the server answers with that many games (and the Forge
        agent connected), printing arena-ready — or, when it does not, exactly
        what is missing, and exits 1
"""

import json
import sys
import time
import urllib.error
import urllib.request

USER = {"X-Aseman-User": "system:smoke", "X-Aseman-User-Handle": "arena-smoke"}

# The server is on this computer: never go through its egress proxy.
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))


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


def wait(base, seconds, games, agent):
    """Polls /healthz until it is ready; on time-out says why it is not."""
    deadline = time.time() + seconds
    last, err = None, ""
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base.rstrip("/") + "/healthz", timeout=5) as r:
                last = json.loads(r.read().decode())
            err = ""
            if last.get("games", 0) >= games and (not agent or last.get("agent")):
                print("arena-ready: %d games, Forge agent %s" % (last["games"], "connected" if last.get("agent") else "not connected"))
                return 0
        except (urllib.error.URLError, OSError, ValueError) as e:
            err = str(e)
        time.sleep(3)
    if last is None:
        print("arena-not-ready: the server does not answer at %s (%s). Is it running? Read its log: the preview's start command is "
              "'cd <app dir> && python3 server.py'." % (base, err or "no answer"))
    elif last.get("games", 0) < games:
        print("arena-not-ready: the store has %d of %d games. Built in %s: %s. Run games/build.sh and check its output."
              % (last.get("games", 0), games, last.get("games_dir"), ", ".join(last.get("built") or []) or "nothing"))
    else:
        print("arena-not-ready: the Forge agent is not connected; missing: %s." % ", ".join(last.get("agent_missing") or ["?"]))
    return 1


def stop_old(app_dir):
    """Stops `python3 server.py` processes running in [app_dir] (also when
    the folder was replaced: their working directory then reads
    "<dir> (deleted)")."""
    import os
    import signal
    app_dir = os.path.realpath(app_dir)
    stopped = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            cmd = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
            cwd = os.readlink("/proc/%s/cwd" % pid)
        except OSError:
            continue
        if int(pid) == os.getpid() or not any(c.endswith(b"server.py") for c in cmd):
            continue
        if cwd.replace(" (deleted)", "") != app_dir:
            continue
        try:
            os.kill(int(pid), signal.SIGTERM)
            stopped.append(pid)
        except OSError:
            pass
    if stopped:
        time.sleep(1.5)
    print("arena-stopped: %s" % (", ".join(stopped) or "none running"))
    return 0


def main():
    if "--stop-old" in sys.argv:
        return stop_old(sys.argv[sys.argv.index("--stop-old") + 1])
    base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
    if "--wait" in sys.argv:
        a = sys.argv
        seconds = int(a[a.index("--wait") + 1])
        games = int(a[a.index("--games") + 1]) if "--games" in a else 2
        return wait(base, seconds, games, "--agent" in a)
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
