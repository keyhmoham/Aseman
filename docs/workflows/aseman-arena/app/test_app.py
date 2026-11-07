"""Tests of Aseman Arena's server: the rules (ratings, levels, plausibility,
manifests, chat hygiene), and the HTTP API end to end on a real server
with a fake Forge agent — people, garages, rooms, matches and results,
leaderboards, achievements, friends and messages, the store and reviews,
the Forge from brief to published game, files, and the visitor's door.

    python3 test_app.py        # prints "N passed"
"""

import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["ARENA_QUIET"] = "1"

import arena  # noqa: E402
import forge  # noqa: E402
import server  # noqa: E402

CHESS = {
    "slug": "arena-chess", "title": "Arena Chess", "version": "1.0.0", "tagline": "Chess vs AI", "description": "Chess.",
    "genre": "board", "tags": ["chess"], "mode": "single-player vs AI", "players": {"humans": 1, "ai": 1}, "engine": "godot-4.3",
    "scene": "res://arena/chess/main.tscn", "pack": "arena-chess.pck", "web": "web/index.html", "accent": "#6aa8ff",
    "settings": {"level": {"type": "integer", "min": 1, "max": 5, "default": 3}, "player_color": {"type": "enum", "values": ["white", "black"], "default": "white"}},
    "pack_sha256": "abcdef0123456789",
}
STRIKE = dict(CHESS, slug="city-strike", title="City Strike", genre="shooter", scene="res://arena/city_strike/main.tscn", pack="city-strike.pck",
              players={"humans": 1, "ai": "3-14"}, settings={"difficulty": {"type": "integer", "min": 1, "max": 5, "default": 3}, "waves": {"type": "integer", "min": 1, "max": 6, "default": 3}})


class FakeForge:
    """The Forge agent, answering at once."""

    ready = True

    def __init__(self):
        self.asked = []

    def open_thread(self, title):
        return "thread-" + title[-4:]

    def ask(self, body, thread=""):
        self.asked.append((body, thread))
        return "Here is my plan: a rooftop racer against three AI drivers."


# ---------------------------------------------------------------------------
# Pure rules
# ---------------------------------------------------------------------------

class Rules(unittest.TestCase):
    def test_elo(self):
        self.assertEqual(arena.elo(1200, 1200, "draw", 20), 1200)
        self.assertGreater(arena.elo(1200, 1900, "win", 20), arena.elo(1200, 800, "win", 20))
        self.assertLess(arena.elo(1500, 800, "loss", 20), 1500)
        # Provisional players move faster.
        self.assertGreater(arena.elo(1200, 1200, "win", 0) - 1200, arena.elo(1200, 1200, "win", 30) - 1200)

    def test_levels(self):
        self.assertEqual(arena.level_for(0), 1)
        self.assertEqual(arena.level_for(100), 2)
        self.assertEqual(arena.level_for(399), 2)
        self.assertEqual(arena.level_for(400), 3)
        p = arena.level_progress(250)
        self.assertEqual((p["level"], p["into"], p["span"]), (2, 150, 300))

    def test_plausible(self):
        ok = {"outcome": "win", "score": 300, "duration_s": 120, "level": 3}
        self.assertEqual(arena.plausible("arena-chess", ok, 130), [])
        self.assertTrue(arena.plausible("arena-chess", dict(ok, outcome="won"), 130))
        self.assertTrue(arena.plausible("arena-chess", dict(ok, score=99999), 130))
        self.assertTrue(arena.plausible("arena-chess", ok, 1), "an instant win is refused")
        self.assertTrue(arena.plausible("arena-chess", dict(ok, duration_s=9999), 100), "claimed time beyond the clock")
        self.assertTrue(arena.plausible("city-strike", {"outcome": "win", "score": 10_000_000, "duration_s": 60}, 60))
        self.assertTrue(arena.plausible("city-strike", {"outcome": "loss", "score": 10, "kills": 500, "duration_s": 60}, 60))
        self.assertTrue(arena.plausible("city-strike", {"outcome": "loss", "score": 10, "accuracy": 3, "duration_s": 60}, 60))

    def test_achievements(self):
        got = arena.earned("arena-chess", {"outcome": "win", "reason": "checkmate", "level": 5}, {"matches": 1, "wins": 1, "streak": 1, "rating:arena-chess": 1300})
        self.assertEqual(set(got), {"first_match", "first_win", "chess_checkmate", "chess_master"})
        got = arena.earned("city-strike", {"outcome": "win", "accuracy": 0.6, "difficulty": 5, "headshots": 12}, {"matches": 4, "wins": 3, "streak": 3})
        self.assertTrue({"city_secured", "city_sharpshooter", "city_veteran", "city_headhunter", "streak_3"} <= set(got))
        self.assertEqual(arena.social_achievements({"friends": 5, "rooms": 3, "published": 1}), ["social_5", "host_3", "creator"])

    def test_manifest(self):
        self.assertEqual(arena.validate_manifest(CHESS), [])
        bad = dict(CHESS, players={"humans": 2, "ai": 0}, mode="multiplayer", scene="main.tscn", slug="Bad Slug")
        problems = " ".join(arena.validate_manifest(bad))
        for word in ("single-player", "AI opponent", "vs AI", "res://", "slug"):
            self.assertIn(word, problems)

    def test_clean_text(self):
        self.assertEqual(arena.clean_text("  hi\x00 there  "), "hi there")
        self.assertEqual(arena.clean_text("shit happens"), "s*** happens")
        self.assertEqual(len(arena.clean_text("x" * 900)), 500)

    def test_forge_brief(self):
        b = forge.brief({"id": "fp_1", "title": "Roof Racer", "genre": "racing", "status": "drafting", "brief": "race"},
                        [{"role": "user", "text": "make it neon"}, {"role": "agent", "text": "ok"}], "go", "aseman-arena")
        for part in ("fp_1", "Roof Racer", "single-player against AI", "arena_event", "arena_forge.py submit", "Person: make it neon", "You: ok", "now says: go"):
            self.assertIn(part, b)


# ---------------------------------------------------------------------------
# The HTTP API
# ---------------------------------------------------------------------------

class Api(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="arena-test-")
        games = os.path.join(cls.tmp, "games")
        for m in (CHESS, STRIKE):
            d = os.path.join(games, m["slug"])
            os.makedirs(os.path.join(d, "web"))
            json.dump(m, open(os.path.join(d, "game.json"), "w"))
            open(os.path.join(d, m["pack"]), "wb").write(b"GDPC" + b"\0" * 64)
            open(os.path.join(d, "web", "index.html"), "w").write("<!doctype html><title>game</title>")
        cfg = server.load_config()
        cfg.update({"data_dir": os.path.join(cls.tmp, "data"), "games_dir": games, "asset_base": "https://arena.example/v1/platforms/arena/app/",
                    "internal_token": "itok", "slug": "aseman-arena", "product": "Aseman Arena"})
        cls.forge = FakeForge()
        cls.app = server.App(cfg, client=cls.forge)
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), server.handler_for(cls.app))
        cls.base = "http://127.0.0.1:%d/" % cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def call(self, method, path, body=None, user=None, headers=None, raw=False):
        h = dict(headers or {})
        if user:
            h["X-Aseman-User"] = "u-" + user
            h["X-Aseman-User-Handle"] = user
        data = json.dumps(body).encode() if body is not None else None
        if data is not None:
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                out = r.read()
                return r.status, (out if raw else json.loads(out or b"{}"))
        except urllib.error.HTTPError as e:
            out = e.read()
            return e.code, (out if raw else json.loads(out or b"{}"))

    def ok(self, method, path, body=None, user=None, status=(200, 201)):
        code, out = self.call(method, path, body, user)
        self.assertIn(code, status if isinstance(status, tuple) else (status,), "%s %s → %s %s" % (method, path, code, out))
        return out

    def play(self, user, slug, room=None, result=None, settings=None, backdate=200):
        out = self.ok("POST", "api/rooms/%s/matches" % room if room else "api/matches", dict({"game": slug}, **(settings or {})), user=user)
        mid, tok = out["match"]["id"], out["match"]["token"]
        # The match started a while ago (results that come too soon are refused).
        self.app.store.x("UPDATE matches SET started_at=started_at-? WHERE id=?", (backdate, mid))
        res = dict({"type": "result", "outcome": "win", "score": 300, "duration_s": 150, "level": out["match"]["settings"].get("level", 3)}, **(result or {}))
        return out, self.ok("POST", "api/matches/%s/result" % mid, dict(res, token=tok))

    # -- the tests -----------------------------------------------------------

    def test_01_visitor(self):
        cfg = self.ok("GET", "api/config")
        self.assertFalse(cfg["signed_in"])
        self.assertIsNone(cfg["me"])
        store = self.ok("GET", "api/store")
        self.assertEqual({g["slug"] for g in store["games"]}, {"arena-chess", "city-strike"})
        chess = [g for g in store["games"] if g["slug"] == "arena-chess"][0]
        self.assertTrue(chess["official"])
        self.assertEqual(chess["launch"]["pack"], "https://arena.example/v1/platforms/arena/app/games/arena-chess/arena-chess.pck?v=abcdef012345")
        self.assertEqual(chess["launch"]["scene"], "res://arena/chess/main.tscn")
        self.ok("GET", "api/leaderboard")
        self.ok("GET", "api/rooms")
        code, out = self.call("GET", "api/garage")
        self.assertEqual(code, 401)
        self.assertIn("Sign in", out["error"])
        code, _ = self.call("POST", "api/rooms", {"name": "x"})
        self.assertEqual(code, 401)
        self.assertEqual(self.ok("GET", "healthz")["games"], 2)

    def test_02_garage(self):
        g = self.ok("GET", "api/garage", user="ana")
        self.assertEqual(g["theme"], "garage")
        files = {i["file"] for i in g["layout"]["items"]}
        self.assertTrue({"covered_car.glb", "rollershutter_door.glb", "tool_chest.glb"} <= files)
        for f in files:
            self.assertTrue(f.endswith(".glb"))
        g = self.ok("PUT", "api/garage", {"theme": "lab"}, user="ana")
        self.assertEqual(g["theme"], "lab")
        self.assertIn("microscope.glb", {i["file"] for i in g["layout"]["items"]})
        code, _ = self.call("PUT", "api/garage", {"theme": "castle"}, user="ana")
        self.assertEqual(code, 400)
        me = self.ok("GET", "api/me", user="ana")
        self.assertEqual((me["handle"], me["progress"]["level"]), ("ana", 1))
        me = self.ok("PATCH", "api/me", {"name": "Ana K", "bio": "chess", "color": "#ff9a5c", "title": "Tactician"}, user="ana")
        self.assertEqual((me["name"], me["color"], me["title"]), ("Ana K", "#ff9a5c", "Tactician"))
        code, _ = self.call("PATCH", "api/me", {"color": "red"}, user="ana")
        self.assertEqual(code, 400)

    def test_03_rooms(self):
        r = self.ok("POST", "api/rooms", {"name": "Friday chess", "game": "arena-chess", "theme": "lounge", "visibility": "public", "settings": {"level": 4}}, user="ana")
        rid = r["id"]
        self.assertTrue(r["is_host"])
        self.assertEqual((r["game_title"], r["theme_info"]["title"], r["members"]), ("Arena Chess", "Midnight Lounge", 1))
        code, _ = self.call("POST", "api/rooms", {"name": "x", "game": "arena-chess"}, user="ana")
        self.assertEqual(code, 400)
        code, _ = self.call("POST", "api/rooms", {"name": "Nope", "game": "missing"}, user="ana")
        self.assertEqual(code, 400)
        grid = self.ok("GET", "api/rooms", user="ben")
        self.assertIn(rid, [x["id"] for x in grid["rooms"]])
        code, _ = self.call("POST", "api/rooms/%s/messages" % rid, {"text": "hi"}, user="ben")
        self.assertEqual(code, 403, "chat needs membership")
        r = self.ok("POST", "api/rooms/%s/join" % rid, user="ben")
        self.assertEqual(r["members"], 2)
        self.ok("POST", "api/rooms/%s/messages" % rid, {"text": "hello shit"}, user="ben")
        msgs = self.ok("GET", "api/rooms/%s/messages" % rid, user="ana")["messages"]
        self.assertEqual(msgs[-1]["text"], "hello s***")
        self.assertIn("joined", " ".join(m["text"] for m in msgs if m["kind"] == "system"))
        after = msgs[-1]["id"]
        self.assertEqual(self.ok("GET", "api/rooms/%s/messages?after=%d" % (rid, after))["messages"], [])
        # Private rooms are hidden from strangers until invited.
        priv = self.ok("POST", "api/rooms", {"name": "Secret lab", "game": "city-strike", "theme": "lab", "visibility": "private"}, user="ana")
        self.assertNotIn(priv["id"], [x["id"] for x in self.ok("GET", "api/rooms", user="cat")["rooms"]])
        code, _ = self.call("GET", "api/rooms/" + priv["id"], user="cat")
        self.assertEqual(code, 404)
        self.ok("POST", "api/rooms/%s/invite" % priv["id"], {"handle": "cat"}, user="ana")
        self.ok("GET", "api/rooms/" + priv["id"], user="cat")
        notes = self.ok("GET", "api/notifications", user="cat")["notifications"]
        self.assertEqual(notes[0]["kind"], "invite")
        # Host rules.
        code, _ = self.call("POST", "api/rooms/%s/leave" % rid, user="ana")
        self.assertEqual(code, 409)
        self.ok("PATCH", "api/rooms/" + rid, {"description": "Bring your best openings"}, user="ana")
        code, _ = self.call("DELETE", "api/rooms/" + rid, user="ben")
        self.assertEqual(code, 403)
        mine = self.ok("GET", "api/rooms?filter=mine", user="ben")["rooms"]
        self.assertEqual([x["id"] for x in mine], [rid])

    def test_04_matches_and_ratings(self):
        r = self.ok("POST", "api/rooms", {"name": "Ranked chess", "game": "arena-chess", "theme": "arena", "settings": {"level": 4}}, user="dan")
        out, res = self.play("dan", "arena-chess", room=r["id"], result={"reason": "checkmate", "level": 4, "score": 400})
        launch = out["launch"]
        self.assertEqual(out["match"]["settings"]["level"], 4, "the room's settings apply")
        self.assertEqual(launch["params"]["level"], 4)
        self.assertTrue(launch["params"]["token"])
        self.assertIn("token=", launch["web"])
        self.assertGreater(res["rating"], arena.START_RATING)
        self.assertGreater(res["xp"], 0)
        self.assertTrue({"first_match", "first_win", "chess_checkmate"} <= {a["id"] for a in res["achievements"]})
        # The same result again is a duplicate, not a second rating.
        mid = out["match"]["id"]
        again = self.ok("POST", "api/matches/%s/result" % mid, {"token": out["match"]["token"], "outcome": "win", "score": 1, "duration_s": 100})
        self.assertTrue(again["duplicate"])
        # A wrong token is refused; a too-fast win is refused.
        out2 = self.ok("POST", "api/matches", {"game": "arena-chess"}, user="dan")
        code, _ = self.call("POST", "api/matches/%s/result" % out2["match"]["id"], {"token": "nope", "outcome": "win"})
        self.assertEqual(code, 403)
        code, err = self.call("POST", "api/matches/%s/result" % out2["match"]["id"], {"token": out2["match"]["token"], "outcome": "win", "score": 100, "duration_s": 1})
        self.assertEqual(code, 422)
        self.assertIn("not believable", err["error"])
        # Settings are clamped to the manifest.
        out3 = self.ok("POST", "api/matches", {"game": "city-strike", "difficulty": 99, "waves": 0}, user="dan")
        self.assertEqual(out3["match"]["settings"], {"difficulty": 5, "waves": 1})
        # The room shows the result and its board.
        room = self.ok("GET", "api/rooms/" + r["id"], user="dan")
        self.assertEqual(room["board"][0]["handle"], "dan")
        msgs = self.ok("GET", "api/rooms/%s/messages" % r["id"], user="dan")["messages"]
        self.assertTrue(any(m["kind"] == "result" and "won Arena Chess" in m["text"] for m in msgs))
        # A loss lowers the rating; streaks.
        _, lost = self.play("dan", "arena-chess", result={"outcome": "loss", "score": 10, "level": 1})
        self.assertLess(lost["rating_change"], 0)
        me = self.ok("GET", "api/me", user="dan")
        self.assertEqual((me["matches"], me["wins"], me["streak"]), (2, 1, 0))

    def test_05_leaderboards_and_profiles(self):
        for who, score in (("eve", 900), ("fay", 1500)):
            self.play(who, "city-strike", result={"score": score, "kills": 9, "headshots": 3, "accuracy": 0.4, "difficulty": 3, "waves_cleared": 3})
        board = self.ok("GET", "api/leaderboard?game=city-strike", user="eve")
        self.assertEqual([r["handle"] for r in board["rows"][:2]], ["fay", "eve"])
        self.assertEqual(board["me"]["rank"], 2)
        self.assertNotIn("user", board["rows"][0], "internal ids stay inside")
        week = self.ok("GET", "api/leaderboard?game=city-strike&period=week")
        self.assertEqual(week["rows"][0]["week_score"], 1500)
        overall = self.ok("GET", "api/leaderboard")
        self.assertTrue(all(r["xp"] > 0 for r in overall["rows"]))
        prof = self.ok("GET", "api/profiles/fay", user="eve")
        self.assertEqual(prof["ratings"][0]["game"], "city-strike")
        self.assertEqual(prof["ratings"][0]["rank"], 1)
        self.assertEqual(prof["friendship"], "none")
        self.assertTrue(any(a["id"] == "city_secured" and a["unlocked"] for a in prof["achievements"]))
        self.assertEqual(prof["recent"][0]["outcome"], "win")
        code, _ = self.call("GET", "api/profiles/nobody")
        self.assertEqual(code, 404)

    def test_06_friends_and_messages(self):
        self.ok("GET", "api/me", user="gus")
        self.ok("GET", "api/me", user="hal")
        code, _ = self.call("POST", "api/messages/hal", {"text": "hi"}, user="gus")
        self.assertEqual(code, 403, "strangers cannot message")
        self.assertEqual(self.ok("POST", "api/friends", {"handle": "hal"}, user="gus")["status"], "requested")
        f = self.ok("GET", "api/friends", user="hal")
        self.assertEqual([u["handle"] for u in f["incoming"]], ["gus"])
        self.ok("POST", "api/friends/gus/accept", user="hal")
        self.assertEqual([u["handle"] for u in self.ok("GET", "api/friends", user="gus")["friends"]], ["hal"])
        self.ok("POST", "api/messages/hal", {"text": "rematch?"}, user="gus")
        threads = self.ok("GET", "api/messages", user="hal")["threads"]
        self.assertEqual((threads[0]["user"]["handle"], threads[0]["unread"]), ("gus", 1))
        thread = self.ok("GET", "api/messages/gus", user="hal")
        self.assertEqual((thread["messages"][-1]["text"], thread["messages"][-1]["mine"]), ("rematch?", False))
        self.assertNotIn("sender", thread["messages"][-1])
        self.assertNotIn("id", thread["with"], "people are known by handle, never by their platform id")
        self.assertEqual(self.ok("GET", "api/messages", user="hal")["threads"][0]["unread"], 0, "reading marks read")
        unread = self.ok("GET", "api/notifications", user="gus")["unread"]
        self.assertGreaterEqual(unread["notifications"], 1)
        self.assertEqual(self.ok("POST", "api/notifications", user="gus")["unread"]["notifications"], 0)
        found = self.ok("GET", "api/users?q=ha", user="gus")["users"]
        self.assertIn("hal", [u["handle"] for u in found])
        self.ok("DELETE", "api/friends/hal", user="gus")
        self.assertEqual(self.ok("GET", "api/friends", user="gus")["friends"], [])
        # Rate limits on chat.
        for i in range(12):
            self.ok("POST", "api/friends", {"handle": "hal"}, user="gus")
        self.ok("POST", "api/friends/gus/accept", user="hal")
        codes = [self.call("POST", "api/messages/hal", {"text": "spam %d" % i}, user="gus")[0] for i in range(14)]
        self.assertIn(429, codes)

    def test_07_store_and_reviews(self):
        code, err = self.call("POST", "api/store/arena-chess/reviews", {"stars": 5, "text": "great"}, user="ivy")
        self.assertEqual(code, 403, "review after playing")
        self.play("ivy", "arena-chess")
        out = self.ok("POST", "api/store/arena-chess/reviews", {"stars": 4, "text": "great AI"}, user="ivy")
        self.assertEqual(out["rating"]["count"], 1)
        detail = self.ok("GET", "api/store/arena-chess", user="ivy")
        self.assertEqual(detail["reviews"][0]["text"], "great AI")
        self.assertIsNotNone(detail["my_rating"])
        self.assertIn("controls", detail)
        self.assertEqual(self.ok("GET", "api/store?q=strike")["games"][0]["slug"], "city-strike")
        self.assertEqual(self.ok("GET", "api/store?genre=board")["games"][0]["slug"], "arena-chess")

    def test_08_files(self):
        code, body = self.call("GET", "games/arena-chess/arena-chess.pck", raw=True)
        self.assertEqual((code, body[:4]), (200, b"GDPC"))
        code, _ = self.call("GET", "games/arena-chess/../../secrets", raw=True)
        self.assertEqual(code, 404)
        code, _ = self.call("GET", "games/nope/x.pck", raw=True)
        self.assertEqual(code, 404)
        code, html = self.call("GET", "", raw=True)
        self.assertEqual(code, 200)
        self.assertIn(b"Aseman Arena", html)
        req = urllib.request.Request(self.base + "play/arena-chess")
        opener = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda *a, **k: None}))
        try:
            opener.open(req)
            self.fail("expected a redirect")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 302)
            self.assertIn("games/arena-chess/web/index.html", e.headers["Location"])

    def test_09_forge(self):
        code, _ = self.call("POST", "api/forge", {"title": "R", "brief": "short"}, user="jay")
        self.assertEqual(code, 400)
        out = self.ok("POST", "api/forge", {"title": "Roof Racer", "brief": "A neon racing game on rooftops against three AI drivers.", "genre": "racing"}, user="jay")
        pid = out["project"]["id"]
        for _ in range(50):
            msgs = self.ok("GET", "api/forge/" + pid, user="jay")["messages"]
            if msgs[-1]["state"] == "done":
                break
            time.sleep(0.05)
        self.assertEqual([m["role"] for m in msgs], ["user", "agent"])
        self.assertIn("rooftop racer", msgs[-1]["text"])
        body, thread = self.forge.asked[-1]
        self.assertTrue(thread, "the project has its own thread")
        self.assertIn(pid, body)
        code, _ = self.call("GET", "api/forge/" + pid, user="kim")
        self.assertEqual(code, 404, "projects are private")
        code, _ = self.call("POST", "api/forge/%s/publish" % pid, user="jay")
        self.assertEqual(code, 409, "nothing built yet")
        # The agent's tool hands over a build.
        build = os.path.join(self.tmp, "forge-build")
        os.makedirs(build, exist_ok=True)
        manifest = dict(CHESS, slug="roof-racer", title="Roof Racer", genre="racing", scene="res://arena/roof_racer/main.tscn", pack="roof-racer.pck", web="")
        open(os.path.join(build, "roof-racer.pck"), "wb").write(b"GDPC")
        code, _ = self.call("POST", "internal/forge/%s/build" % pid, {"manifest": manifest, "dir": build})
        self.assertEqual(code, 403, "internal needs the token")
        code, out = self.call("POST", "internal/forge/%s/build" % pid, {"manifest": dict(manifest, players={"humans": 4}), "dir": build}, headers={"Authorization": "Bearer itok"})
        self.assertEqual(code, 422)
        code, out = self.call("POST", "internal/forge/%s/build" % pid, {"manifest": manifest, "dir": build}, headers={"Authorization": "Bearer itok"})
        self.assertEqual((code, out["status"]), (200, "testing"))
        # In testing: its author sees it and can play it privately; others do not.
        self.assertIn("roof-racer", [g["slug"] for g in self.ok("GET", "api/store", user="jay")["games"]])
        self.assertNotIn("roof-racer", [g["slug"] for g in self.ok("GET", "api/store", user="kim")["games"]])
        code, _ = self.call("POST", "api/rooms", {"name": "Test track", "game": "roof-racer", "visibility": "public"}, user="jay")
        self.assertEqual(code, 400)
        self.ok("POST", "api/rooms", {"name": "Test track", "game": "roof-racer", "visibility": "private"}, user="jay")
        self.ok("POST", "api/matches", {"game": "roof-racer"}, user="jay")
        pub = self.ok("POST", "api/forge/%s/publish" % pid, user="jay")
        self.assertEqual(pub["status"], "published")
        self.assertIn("creator", [a["id"] for a in pub["achievements"]])
        g = [x for x in self.ok("GET", "api/store", user="kim")["games"] if x["slug"] == "roof-racer"][0]
        self.assertEqual((g["author"], g["official"]), ("jay", False))
        # Another person cannot take the slug.
        other = self.ok("POST", "api/forge", {"title": "Copy", "brief": "A copy of the rooftop racer with more AI drivers.", "genre": "racing"}, user="kim")["project"]["id"]
        code, out = self.call("POST", "internal/forge/%s/build" % other, {"manifest": manifest, "dir": build}, headers={"Authorization": "Bearer itok"})
        self.assertEqual(code, 409)

    def test_11_no_internal_ids(self):
        """What one person sees of others never carries platform ids."""
        r = self.ok("POST", "api/rooms", {"name": "Id check", "game": "arena-chess"}, user="zed")
        self.ok("POST", "api/rooms/%s/join" % r["id"], user="yan")
        self.ok("POST", "api/rooms/%s/messages" % r["id"], {"text": "hi"}, user="yan")
        self.play("yan", "arena-chess", room=r["id"])
        self.ok("POST", "api/store/arena-chess/reviews", {"stars": 5, "text": "ok"}, user="yan")
        for path in ("api/rooms/" + r["id"], "api/rooms/%s/messages" % r["id"], "api/store/arena-chess", "api/profiles/yan", "api/leaderboard?game=arena-chess", "api/rooms"):
            text = json.dumps(self.ok("GET", path, user="zed"))
            self.assertNotIn("u-yan", text, path)

    def test_12_keep_alive_bodies(self):
        """A POST whose route ignores its body must not poison the next
        request on the same connection."""
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        h = {"X-Aseman-User": "u-ka", "X-Aseman-User-Handle": "ka", "Content-Type": "application/json"}
        c.request("POST", "/api/notifications", body="{}", headers=h)
        r = c.getresponse()
        r.read()
        self.assertEqual(r.status, 200)
        c.request("GET", "/api/forge", headers=h)
        r = c.getresponse()
        self.assertEqual(r.status, 200, r.read()[:200])
        c.close()

    def test_10_social_achievements(self):
        for h in ("m1", "m2", "m3", "m4", "m5"):
            self.ok("GET", "api/me", user=h)
            self.ok("POST", "api/friends", {"handle": h}, user="lea")
            self.ok("POST", "api/friends/lea/accept", user=h)
        for i in range(3):
            self.ok("POST", "api/rooms", {"name": "Room %d" % i, "game": "arena-chess"}, user="lea")
        prof = self.ok("GET", "api/me", user="lea")
        got = {a["id"] for a in prof["achievements"] if a["unlocked"]}
        self.assertTrue({"social_5", "host_3"} <= got)
        self.assertGreaterEqual(prof["xp"], 200)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if result.wasSuccessful():
        print("%d passed" % result.testsRun)
    sys.exit(0 if result.wasSuccessful() else 1)
