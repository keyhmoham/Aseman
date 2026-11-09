"""Tests for Persian Rails Empire platform server.

    python3 test_app.py
"""

import json
import os
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
os.environ["RAILS_QUIET"] = "1"

import rails  # noqa: E402
import server  # noqa: E402
import store as storemod  # noqa: E402


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode())


def post(url, body, headers=None):
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode())


class RailsUnit(unittest.TestCase):
    def test_elo(self):
        a = rails.elo(1200, 1200, 1)
        self.assertGreater(a, 1200)

    def test_believable(self):
        ok, _ = rails.believable_result({"outcome": "win", "score": 80, "ai_score": 40, "level": 2, "moves": 20}, 2, 60)
        self.assertTrue(ok)
        bad, why = rails.believable_result({"outcome": "win", "score": 10, "ai_score": 40, "level": 2, "moves": 20}, 2, 60)
        self.assertFalse(bad)

    def test_map_data(self):
        cities = rails.load_json("cities.json")
        routes = rails.load_json("routes.json")
        self.assertGreaterEqual(len(cities), 30)
        self.assertGreaterEqual(len(routes), 45)


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        gdir = os.path.join(cls.tmp, "games", "persian-rails")
        os.makedirs(gdir)
        gpath = os.path.join(HERE, "..", "games", "persian-rails", "game.json")
        if os.path.isfile(gpath):
            with open(gpath, encoding="utf-8") as f:
                g = json.load(f)
        else:
            g = {
                "slug": "persian-rails",
                "title": "امپراتوری راه‌آهن پارس",
                "version": "1.0.0",
                "tagline": "test",
                "engine": "godot-4.3",
                "scene": "res://arena/persian_rails/main.tscn",
                "pack": "persian-rails.pck",
                "settings": {},
                "accent": "#156a87",
            }
        with open(os.path.join(gdir, "game.json"), "w", encoding="utf-8") as f:
            json.dump(g, f, ensure_ascii=False)
        open(os.path.join(gdir, "persian-rails.pck"), "wb").write(b"GDPC")
        cfg = server.load_config()
        cfg["data_dir"] = os.path.join(cls.tmp, "data")
        cfg["games_dir"] = os.path.join(cls.tmp, "games")
        cfg["quiet"] = "1"
        cls.app = server.App(cfg)
        handler = server.make_handler(cls.app)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        cls.port = cls.httpd.server_address[1]
        cls.base = "http://127.0.0.1:%d" % cls.port
        t = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        t.start()
        time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def test_health(self):
        h = get(self.base + "/healthz")
        self.assertTrue(h["ok"])
        self.assertEqual(h["game"], "persian-rails")

    def test_me_and_match(self):
        headers = {"X-Aseman-User": "u_test_1", "X-Aseman-Handle": "sara", "X-Aseman-Name": "Sara"}
        me = get(self.base + "/api/me", headers=headers)
        self.assertEqual(me["me"]["handle"], "sara")
        self.assertIn("fa", me)
        m = post(self.base + "/api/matches", {"level": 2, "player_name": "Sara"}, headers=headers)
        self.assertIn("token", m["match"])
        token = m["match"]["token"]
        body = {"outcome": "win", "score": 90, "ai_score": 55, "level": 2, "moves": 24, "duration_s": 80}
        # wait so duration from created_at is fine — we check elapsed from server clock
        time.sleep(0.05)
        # believable requires elapsed_s >= 15 for wins — inject by finishing with draw or patch store time
        # Use loss/draw or temporarily lower — call finish with draw which allows faster? win needs 15s.
        # Directly age the match.
        with self.app.store.lock:
            self.app.store.conn.execute("UPDATE matches SET created_at=? WHERE token=?", (time.time() - 30, token))
            self.app.store.conn.commit()
        res = post(self.base + "/api/matches/%s/result" % token, body, headers=headers)
        self.assertEqual(res["outcome"], "win")
        self.assertGreater(res["rating_after"], res["rating_before"] - 1)

    def test_atlas_and_board(self):
        a = get(self.base + "/api/atlas")
        self.assertGreaterEqual(len(a["culture"]), 5)
        b = get(self.base + "/api/leaderboard")
        self.assertIn("board", b)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    n = result.testsRun - len(result.failures) - len(result.errors)
    print("%d passed" % n)
    sys.exit(0 if result.wasSuccessful() else 1)
