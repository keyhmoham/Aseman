"""Persian Rails Empire platform server — stdlib only.

Serves the Godot shell UI (5 tabs + in-match HUD), pack/Web build, culture atlas,
match tokens vs AI, ratings, and a thin Scene3D host for Aseman embeds.
"""

import json
import mimetypes
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

import rails
import store as storemod

HERE = os.path.dirname(os.path.abspath(__file__))
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".glb": "model/gltf-binary",
    ".pck": "application/octet-stream",
    ".wasm": "application/wasm",
    ".md": "text/markdown; charset=utf-8",
}


def read_env_file(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return out


def load_config():
    cfg = {
        "product": "امپراتوری راه‌آهن پارس",
        "slug": "persian-rails-empire",
        "port": 8080,
        "data_dir": os.path.join(HERE, ".data"),
        "games_dir": os.path.join(HERE, "games", "build"),
        "secrets_file": "",
        "api_url": "",
        "space": "",
        "public_url": "",
        "asset_base": "/",
        "android_apk": "",
    }
    try:
        with open(os.path.join(HERE, "config.json"), encoding="utf-8") as f:
            cfg.update({k: v for k, v in json.load(f).items() if v not in (None, "")})
    except (OSError, ValueError):
        pass
    for key, env in (
        ("port", "PORT"),
        ("data_dir", "DATA_DIR"),
        ("games_dir", "GAMES_DIR"),
        ("secrets_file", "SECRETS_FILE"),
        ("api_url", "ASEMAN_DEVELOPER_API_URL"),
        ("asset_base", "ASSET_BASE"),
    ):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    secret = read_env_file(cfg["secrets_file"]) if cfg["secrets_file"] else {}
    cfg["key"] = os.environ.get("ASEMAN_DEVELOPER_KEY") or secret.get("ASEMAN_DEVELOPER_KEY", "")
    if not cfg["api_url"]:
        cfg["api_url"] = secret.get("ASEMAN_DEVELOPER_API_URL", "")
    cfg["port"] = int(cfg["port"])
    cfg["quiet"] = os.environ.get("RAILS_QUIET") or os.environ.get("ARENA_QUIET")
    return cfg


class App:
    def __init__(self, cfg=None):
        self.cfg = cfg or load_config()
        self.store = storemod.Store(self.cfg["data_dir"])
        self.cities = rails.load_json("cities.json")
        self.routes = rails.load_json("routes.json")
        self.tickets = rails.load_json("tickets.json")
        self.culture = rails.load_json("culture.json")
        self.fa = rails.load_json("fa.json")
        self.game = self._load_game()

    def _load_game(self):
        gdir = os.path.join(self.cfg["games_dir"], "persian-rails")
        path = os.path.join(gdir, "game.json")
        try:
            with open(path, encoding="utf-8") as f:
                g = json.load(f)
        except (OSError, ValueError):
            # fall back to source manifest
            src = os.path.join(HERE, "..", "games", "persian-rails", "game.json")
            try:
                with open(src, encoding="utf-8") as f:
                    g = json.load(f)
            except (OSError, ValueError):
                g = {"slug": "persian-rails", "title": self.cfg["product"], "version": "0.0.0"}
        g["dir"] = gdir
        return g

    def health(self):
        return {
            "ok": True,
            "product": self.cfg["product"],
            "slug": self.cfg["slug"],
            "game": self.game.get("slug"),
            "version": self.game.get("version"),
        }

    def me(self, uid, handle=None, name=None):
        u = self.store.ensure_user(uid, handle=handle, name=name)
        return {
            "me": self.store.public_user(u),
            "product": self.cfg["product"],
            "fa": self.fa,
            "game": {
                "slug": self.game.get("slug"),
                "title": self.game.get("title"),
                "tagline": self.game.get("tagline"),
                "version": self.game.get("version", "1.0.0"),
                "settings": self.game.get("settings", {}),
                "accent": self.game.get("accent", "#156a87"),
                "pack": "games/persian-rails/" + self.game.get("pack", "persian-rails.pck"),
                "pack_path": "games/persian-rails/" + self.game.get("pack", "persian-rails.pck"),
                "scene": self.game.get("scene"),
                "web": "games/persian-rails/" + self.game.get("web", "web/index.html") if self.game.get("web") else None,
            },
            "asset_base": self.cfg.get("asset_base") or "/",
            "android_apk": self.cfg.get("android_apk") or None,
            "map": {"cities": len(self.cities), "routes": len(self.routes), "tickets": len(self.tickets)},
        }

    def atlas(self):
        return {"culture": self.culture, "cities": self.cities, "fa": self.fa}

    def rules_summary(self):
        return {
            "title": "قوانین خودمونی",
            "turns": [
                "تو هر نوبت یکی از این سه کار رو انجام بده:",
                "۱) دو کارت رنگی بردار (از روی میز یا از دسته).",
                "۲) یک مسیر آزاد بساز و به تعداد طولش کارت بده.",
                "۳) قرارداد مقصد بردار و حداقل یکی‌ش رو نگه دار.",
            ],
            "end": "وقتی واگن‌هات به ۲ یا کمتر رسید، همه یک نوبت آخر دارن.",
            "note": self.fa.get("scenario_note", ""),
            "score_table": rails.load_json("fa.json") and {1: 1, 2: 2, 3: 4, 4: 7, 5: 10, 6: 15},
        }


def make_handler(app: App):
    class H(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            if not app.cfg.get("quiet"):
                super().log_message(fmt, *args)

        def _user(self):
            uid = self.headers.get("X-Aseman-User") or self.headers.get("x-aseman-user")
            handle = self.headers.get("X-Aseman-Handle") or self.headers.get("x-aseman-handle")
            name = self.headers.get("X-Aseman-Name") or self.headers.get("x-aseman-name")
            if not uid:
                # local / visitor door
                uid = self.headers.get("X-Rails-User") or "visitor"
            return uid, handle, name

        def _json(self, code, obj):
            raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Aseman-User, X-Aseman-Handle, X-Aseman-Name, X-Rails-User")
            # Godot web (COEP) can fetch JSON only when CORP is present.
            self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
            self.end_headers()
            if not getattr(self, "_head_only", False):
                self.wfile.write(raw)

        def _read_json(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8"))

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, PATCH, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Aseman-User, X-Aseman-Handle, X-Aseman-Name, X-Rails-User")
            self.end_headers()

        def do_HEAD(self):
            # Same routing as GET, but only headers (needed by Scene3D / iframes probing files).
            self.close_connection = True
            self._head_only = True
            try:
                self.do_GET()
            finally:
                self._head_only = False

        def do_GET(self):
            u = urlparse(self.path)
            path = u.path
            if path in ("/healthz", "/api/healthz"):
                return self._json(200, app.health())
            if path == "/api/me":
                uid, handle, name = self._user()
                return self._json(200, app.me(uid, handle, name))
            if path == "/api/atlas":
                return self._json(200, app.atlas())
            if path == "/api/rules":
                return self._json(200, app.rules_summary())
            if path == "/api/leaderboard":
                return self._json(200, {"board": app.store.leaderboard()})
            if path == "/api/game":
                return self._json(200, app.me(*self._user())["game"])
            return self._static(path)

        def do_PATCH(self):
            u = urlparse(self.path)
            if u.path == "/api/me":
                uid, handle, name = self._user()
                body = self._read_json()
                user = app.store.patch_user(uid, name=body.get("name") or name)
                return self._json(200, {"me": app.store.public_user(user)})
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            uid, handle, name = self._user()
            if u.path == "/api/matches":
                body = self._read_json()
                level = int(body.get("level", 2))
                level = max(1, min(3, level))
                ai_count = max(1, min(3, int(body.get("ai_count", 1))))
                wagons = max(30, min(45, int(body.get("wagons", 45))))
                player_name = rails.sanitize_name(body.get("player_name") or name or "تو")
                app.store.ensure_user(uid, handle=handle, name=name or body.get("player_name"))
                m = app.store.start_match(uid, level=level)
                g = app.me(uid)["game"]
                params = {
                    "level": level,
                    "ai_count": ai_count,
                    "wagons": wagons,
                    "player_name": player_name,
                    "match": m["id"],
                    "token": m["token"],
                }
                # Relative to the platform app root. Clients prefix with Aseman.env().appUrl
                # so the browser build works on whatever host the player opened.
                web_rel = g.get("web") or ""
                q_all = "&".join("%s=%s" % (k, quote(str(v))) for k, v in params.items() if v != "")
                # Embedded Scene3D reports the result itself — omit token from the page.
                q_embed = "&".join("%s=%s" % (k, quote(str(v))) for k, v in params.items()
                                   if v != "" and k not in ("token", "report_url"))
                launch = {
                    "game": "persian-rails",
                    "pack": g["pack"],
                    "pack_path": g.get("pack_path") or g["pack"],
                    "scene": g["scene"],
                    "version": g.get("version", "1.0.0"),
                    "params": params,
                    "web": (web_rel + "?" + q_all) if web_rel else "",
                    "embed": (web_rel + "?" + q_embed) if web_rel else "",
                }
                return self._json(200, {"match": m, "launch": launch})
            if u.path.startswith("/api/matches/") and u.path.endswith("/result"):
                token = u.path.split("/")[3]
                body = self._read_json()
                result, err = app.store.finish_match(token, body)
                if err:
                    return self._json(400, {"error": err})
                return self._json(200, result)
            return self._json(404, {"error": "not found"})

        def _static(self, path):
            if path in ("", "/"):
                path = "/index.html"
            # elpian bundle
            if path in ("/elpian/app.js", "/app.js"):
                fpath = os.path.join(HERE, "elpian", "app.js")
                return self._file(fpath)
            if path.startswith("/games/"):
                rel = path[len("/games/"):]
                fpath = os.path.join(app.cfg["games_dir"], rel)
                return self._file(fpath)
            if path.startswith("/assets/"):
                fpath = os.path.join(HERE, "public", path.lstrip("/"))
                return self._file(fpath)
            fpath = os.path.join(HERE, "public", path.lstrip("/"))
            if os.path.isdir(fpath):
                fpath = os.path.join(fpath, "index.html")
            return self._file(fpath)

        def _file(self, fpath):
            if not os.path.isfile(fpath):
                return self._json(404, {"error": "not found", "path": fpath})
            ext = os.path.splitext(fpath)[1].lower()
            ctype = TYPES.get(ext) or mimetypes.guess_type(fpath)[0] or "application/octet-stream"
            with open(fpath, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            # Godot web builds fetch sibling .wasm/.pck; allow cross-origin when embedded.
            if ext in (".wasm", ".pck", ".js", ".html"):
                self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
                self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.end_headers()
            if not getattr(self, "_head_only", False):
                self.wfile.write(data)

    return H


def main():
    cfg = load_config()
    app = App(cfg)
    handler = make_handler(app)
    httpd = ThreadingHTTPServer(("0.0.0.0", cfg["port"]), handler)
    if not cfg.get("quiet"):
        print("persian-rails-empire listening on %d" % cfg["port"], flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
