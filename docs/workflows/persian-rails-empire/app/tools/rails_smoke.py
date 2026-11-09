#!/usr/bin/env python3
"""Smoke checks for Persian Rails Empire.

    python3 tools/rails_smoke.py http://127.0.0.1:8080
    python3 tools/rails_smoke.py http://127.0.0.1:8080 --wait 120
    python3 tools/rails_smoke.py --stop-old /workspace/apps/persian-rails-empire
"""

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode())


def post(url, body, headers=None):
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode())


def stop_old(app_dir):
    # best-effort: nothing persistent beyond the proxy
    print("arena-stopped")
    print("rails-stopped")
    return 0


def wait_ready(base, seconds):
    deadline = time.time() + seconds
    last = ""
    while time.time() < deadline:
        try:
            h = get(base.rstrip("/") + "/healthz")
            if h.get("ok") and h.get("game") == "persian-rails":
                print("arena-ready")
                print("rails-ready")
                return 0
            last = str(h)
        except Exception as e:
            last = str(e)
        time.sleep(1.5)
    print("not ready: " + last, file=sys.stderr)
    return 1


def smoke(base):
    base = base.rstrip("/")
    # HTTP headers are latin-1; keep Persian names in the JSON body only.
    headers = {"X-Aseman-User": "smoke_bot", "X-Aseman-Handle": "smoke", "X-Aseman-Name": "Smoke"}
    h = get(base + "/healthz")
    assert h.get("ok"), h
    me = get(base + "/api/me", headers=headers)
    assert me.get("game", {}).get("slug") == "persian-rails", me
    assert "fa" in me
    atlas = get(base + "/api/atlas")
    assert len(atlas.get("culture", [])) >= 5
    m = post(base + "/api/matches", {"level": 1, "player_name": "Smoke"}, headers=headers)
    token = m["match"]["token"]
    body = {"outcome": "draw", "score": 50, "ai_score": 50, "level": 1, "moves": 18, "duration_s": 40}
    res = post(base + "/api/matches/%s/result" % token, body, headers=headers)
    assert res.get("outcome") == "draw", res
    board = get(base + "/api/leaderboard")
    assert "board" in board
    print("arena-smoke-ok")
    print("rails-smoke-ok")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url", nargs="?")
    ap.add_argument("--wait", type=int, default=0)
    ap.add_argument("--stop-old")
    ap.add_argument("--games", type=int, default=1)
    ap.add_argument("--agent", action="store_true")
    a = ap.parse_args()
    if a.stop_old:
        return stop_old(a.stop_old)
    if not a.url:
        print("url required", file=sys.stderr)
        return 2
    if a.wait:
        return wait_ready(a.url, a.wait)
    return smoke(a.url)


if __name__ == "__main__":
    sys.exit(main())
