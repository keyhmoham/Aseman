"""Aseman Arena's server: the platform's backend and the files its clients
load. Standard library only.

  People      GET/PATCH api/me, api/profiles/<handle>, api/users?q=
  Garage      GET/PUT api/garage (the person's 3D home: theme and decor)
  Rooms       api/rooms (grid, create), api/rooms/<id> (+ join, leave, invite,
              messages, matches), each room bound to one game of the store
  Matches     POST api/rooms/<id>/matches or api/matches (practice) → a one-time
              token and how to launch the game; POST api/matches/<id>/result
  Leaderboard api/leaderboard?game=&period=week|all, api/achievements
  Social      api/friends, api/messages[/<handle>], api/notifications
  Store       api/store, api/store/<slug> (+ reviews)
  Forge       api/forge (projects), api/forge/<id> (+ messages, publish): people
              chat with the Forge agent, which builds games and submits them
  Files       elpian/app.js, assets/models/*.glb, games/<slug>/… (packs, web
              builds), / (the web hub), play/<slug> (browser practice)
  Internal    internal/forge/<id>/build, internal/games/sync (bearer token)

The person is the one the platform's gateway names (X-Aseman-User,
X-Aseman-User-Handle); without it a request is a visitor's, who can read
the store, rooms and leaderboards and nothing else. Settings: config.json
beside this file, then the environment; secrets from the secrets file.
"""

import json
import mimetypes
import os
import re
import secrets as rnd
import shutil
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

import arena
import forge
from store import Store, now

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLIC = os.path.join(HERE, "public")
ELPIAN = os.path.join(HERE, "elpian", "app.js")
DATA = os.path.join(HERE, "data")
UID = re.compile(r"^[a-zA-Z0-9_.:@-]{1,80}$")
TYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".svg": "image/svg+xml", ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg", ".glb": "model/gltf-binary",
         ".pck": "application/octet-stream", ".wasm": "application/wasm", ".ico": "image/x-icon", ".md": "text/markdown; charset=utf-8"}


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
    cfg = {"product": "Aseman Arena", "slug": "aseman-arena", "port": 8080, "data_dir": os.path.join(HERE, ".data"),
           "games_dir": os.path.join(HERE, "games", "build"), "forge_dir": "/workspace/forge",
           "api_url": "", "space": "", "forge_bot": "", "forge_room": "", "secrets_file": "",
           "asset_base": "", "public_url": "", "android_apk": ""}
    try:
        with open(os.path.join(HERE, "config.json"), encoding="utf-8") as f:
            cfg.update({k: v for k, v in json.load(f).items() if v not in (None, "")})
    except (OSError, ValueError):
        pass
    for key, env in (("port", "PORT"), ("data_dir", "DATA_DIR"), ("games_dir", "GAMES_DIR"), ("api_url", "ASEMAN_DEVELOPER_API_URL"),
                     ("space", "ARENA_SPACE"), ("forge_bot", "FORGE_BOT"), ("forge_room", "FORGE_ROOM"), ("secrets_file", "SECRETS_FILE"),
                     ("asset_base", "ASSET_BASE"), ("forge_dir", "FORGE_DIR")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    secret = read_env_file(cfg["secrets_file"]) if cfg["secrets_file"] else {}
    cfg["key"] = os.environ.get("ASEMAN_DEVELOPER_KEY") or secret.get("ASEMAN_DEVELOPER_KEY", "")
    cfg["internal_token"] = os.environ.get("ARENA_INTERNAL_TOKEN") or secret.get("ARENA_INTERNAL_TOKEN", "")
    if not cfg["api_url"]:
        cfg["api_url"] = secret.get("ASEMAN_DEVELOPER_API_URL", "")
    if not cfg["asset_base"] and cfg.get("public_url"):
        cfg["asset_base"] = cfg["public_url"].rstrip("/") + "/v1/platforms/%s/app/" % cfg["slug"]
    cfg["port"] = int(cfg["port"])
    return cfg


class HTTPError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def need(cond, status, message):
    if not cond:
        raise HTTPError(status, message)


def public_user(u, store=None, full=False):
    """A person as others see them."""
    if not u:
        return None
    out = {"handle": u["handle"], "name": u["name"], "color": u["color"], "title": u["title"],
           "level": arena.level_for(u["xp"]), "xp": u["xp"], "online": now() - u["last_seen"] < 120,
           "last_seen": u["last_seen"]}
    if full:
        out.update({"bio": u["bio"], "garage_theme": u["garage_theme"], "favorite_game": u["favorite_game"],
                    "matches": u["matches"], "wins": u["wins"], "streak": u["streak"], "best_streak": u["best_streak"],
                    "progress": arena.level_progress(u["xp"]), "joined": u["created_at"]})
    return out


def dm_rows(rows, me):
    """Direct messages as their reader sees them: whose they are, not ids."""
    return [{"id": r["id"], "text": r["text"], "at": r["at"], "mine": r["sender"] == me, "read": bool(r["read"])} for r in rows]


class RateLimit:
    def __init__(self, per, window):
        self.per, self.window, self.hits, self.lock = per, window, {}, threading.Lock()

    def ok(self, key):
        t = time.time()
        with self.lock:
            hist = [x for x in self.hits.get(key, []) if t - x < self.window]
            if len(hist) >= self.per:
                self.hits[key] = hist
                return False
            hist.append(t)
            self.hits[key] = hist
            return True


class App:
    def __init__(self, cfg=None, client=None):
        self.cfg = cfg or load_config()
        self.store = Store(self.cfg["data_dir"])
        self.client = client or forge.Client(self.cfg["api_url"], self.cfg["key"], self.cfg["space"], self.cfg["forge_bot"], self.cfg["forge_room"])
        self.chat_limit = RateLimit(12, 15)
        self.garages = json.load(open(os.path.join(DATA, "garages.json"), encoding="utf-8"))
        self.threads = {}
        self.sync_games()

    # ------------------------------------------------------------------
    # The catalogue: official games from the build folder
    # ------------------------------------------------------------------

    def sync_games(self):
        """Every built official game (games_dir/<slug>/game.json) is in the
        store at its built version."""
        found = []
        root = self.cfg["games_dir"]
        if os.path.isdir(root):
            for slug in sorted(os.listdir(root)):
                path = os.path.join(root, slug, "game.json")
                if not os.path.isfile(path):
                    continue
                try:
                    m = json.load(open(path, encoding="utf-8"))
                except ValueError:
                    continue
                if arena.validate_manifest(m):
                    continue
                self.store.upsert_game(m, {"dir": os.path.join(root, slug)}, "published", "", official=True)
                found.append(slug)
        return found

    def game_dir(self, game):
        return game["files"].get("dir", "")

    def asset_base(self):
        return self.cfg.get("asset_base") or ""

    def game_view(self, g, viewer=None, detail=False):
        m = g["manifest"]
        base = self.asset_base()
        v = m.get("pack_sha256", g["version"])[:12]
        out = {
            "slug": g["slug"], "title": m["title"], "tagline": m.get("tagline", ""), "genre": m.get("genre", ""),
            "tags": m.get("tags", []), "version": g["version"], "accent": m.get("accent", "#6aa8ff"), "mode": m.get("mode", ""),
            "players": m.get("players", {}), "official": bool(g["official"]), "status": g["status"], "plays": g["plays"],
            "rating": self.store.rating_summary(g["slug"]), "settings": m.get("settings", {}),
            "launch": {"pack": "%sgames/%s/%s?v=%s" % (base, g["slug"], m["pack"], v), "scene": m["scene"], "version": v,
                       "web": "games/%s/%s" % (g["slug"], m.get("web", "")) if m.get("web") else ""},
            "icon": "games/%s/icon.svg" % g["slug"],
        }
        if g["author"]:
            a = self.store.user(g["author"])
            out["author"] = a["handle"] if a else ""
        if detail:
            out.update({"description": m.get("description", ""), "scoring": m.get("scoring", ""), "controls": m.get("controls", []),
                        "credits": m.get("credits", []), "pack_bytes": m.get("pack_bytes", 0),
                        "reviews": self.store.reviews(g["slug"]),
                        "leaders": self.store.leaderboard(g["slug"], "all", 10),
                        "rooms": [self.room_view(r, viewer) for r in self.store.rooms(viewer, game=g["slug"], limit=8)]})
            if viewer:
                mine = self.store.rating(viewer, g["slug"])
                out["my_rating"] = {k: v for k, v in mine.items() if k != "user"} if mine else None
                out["my_rank"] = self.store.rank_of(viewer, g["slug"])
        return out

    def visible_game(self, slug, viewer):
        g = self.store.game(slug)
        if not g:
            return None
        if g["status"] == "published" or (viewer and g["author"] == viewer):
            return g
        return None

    # ------------------------------------------------------------------
    # Rooms
    # ------------------------------------------------------------------

    def room_view(self, r, viewer=None, detail=False):
        g = self.store.game(r["game"])
        theme = arena.ROOM_THEMES.get(r["theme"], arena.ROOM_THEMES["arena"])
        out = {"id": r["id"], "name": r["name"], "game": r["game"], "game_title": g["manifest"]["title"] if g else r["game"],
               "game_accent": g["manifest"].get("accent", theme["accent"]) if g else theme["accent"],
               "theme": r["theme"], "theme_info": theme, "visibility": r["visibility"], "host": r["host_handle"],
               "host_name": r["host_name"], "members": r["members"], "max_members": r["max_members"], "online": r.get("online", 0),
               "joined": bool(r.get("joined")) if "joined" in r else (bool(viewer) and self.store.is_member(r["id"], viewer)),
               "settings": r["settings"], "description": r["description"], "last_active": r["last_active"]}
        if detail:
            out["member_list"] = [dict(public_user(self.store.user(m["id"])), role=m["role"]) for m in self.store.members(r["id"])]
            out["board"] = self.store.room_board(r["id"])
            out["game_info"] = self.game_view(g, viewer) if g else None
            out["is_host"] = bool(viewer) and self.store.user(viewer) is not None and r["host"] == viewer
        return out

    # ------------------------------------------------------------------
    # Matches and results
    # ------------------------------------------------------------------

    def launch(self, uid, game, room, choices):
        """Starts a match: the game's settings (the room's, then the
        person's choices, within the manifest's bounds) and a one-time token."""
        m = game["manifest"]
        settings = {}
        for key, spec in (m.get("settings") or {}).items():
            v = choices.get(key, (room or {}).get("settings", {}).get(key, spec.get("default")))
            if spec.get("type") == "integer":
                try:
                    v = int(v)
                except (TypeError, ValueError):
                    v = spec.get("default")
                v = max(spec.get("min", v), min(spec.get("max", v), v))
            elif spec.get("type") == "enum" and v not in spec.get("values", []):
                v = spec.get("default")
            settings[key] = v
        match = self.store.start_match(uid, game["slug"], room["id"] if room else "", settings)
        user = self.store.user(uid)
        params = dict(settings, player_name=user["name"], match=match["id"], token=match["token"],
                      report_url=self.asset_base() + "api/matches/%s/result" % match["id"] if self.asset_base() else "")
        view = self.game_view(game, uid)
        web = embed = ""
        if view["launch"]["web"]:
            web = view["launch"]["web"] + "?" + "&".join("%s=%s" % (k, quote(str(v))) for k, v in params.items() if v != "")
            # Embedded in the app (a client without the 3D engine runs the
            # browser build in the Scene3D): the app reports the result, so
            # the page gets neither the token nor where to send it.
            embed = view["launch"]["web"] + "?" + "&".join("%s=%s" % (k, quote(str(v))) for k, v in params.items()
                                                          if v != "" and k not in ("token", "report_url"))
        if room:
            self.store.post(room["id"], uid, "%s started %s" % (user["handle"], m["title"]), kind="system")
        return {"match": {"id": match["id"], "token": match["token"], "game": game["slug"], "settings": settings},
                "launch": dict(view["launch"], params=params, web=web, embed=embed)}

    def finish(self, mid, body):
        match = self.store.match(mid)
        need(match is not None, 404, "no such match")
        need(rnd.compare_digest(str(body.get("token", "")), match["token"]), 403, "this result is not signed by its match")
        if match["status"] != "playing":
            return {"duplicate": True, "match": self._match_out(match)}
        result = {k: v for k, v in body.items() if k != "token" and not isinstance(v, (dict, list))}
        if isinstance(body.get("pgn"), str):
            result["pgn"] = body["pgn"][:20000]
        elapsed = now() - match["started_at"]
        problems = arena.plausible(match["game"], result, elapsed)
        need(not problems, 422, "; ".join(problems))
        uid, game = match["user"], match["game"]
        outcome = result["outcome"]
        score = int(result.get("score") or 0)
        lvl = int(result.get("level") or result.get("difficulty") or match["settings"].get("level") or match["settings"].get("difficulty") or 3)
        before = self.store.rating(uid, game)
        rating = before["rating"] if before else arena.START_RATING
        new_rating = arena.elo(rating, arena.AI_RATING.get(lvl, 1400), outcome, before["games"] if before else 0)
        xp = arena.match_xp(game, result)
        self.store.finish_match(mid, result, outcome, score, xp, new_rating - rating)
        self.store.save_rating(uid, game, new_rating, score, outcome)
        user = self.store.record_result_stats(uid, outcome, xp)
        stats = {"matches": user["matches"], "wins": user["wins"], "streak": user["streak"], "rating:" + game: new_rating}
        unlocked = self.unlock(uid, arena.earned(game, result, stats))
        g = self.store.game(game)
        title = g["manifest"]["title"] if g else game
        if match["room"]:
            verb = {"win": "won", "loss": "lost", "draw": "drew"}[outcome]
            what = "vs level %d" % lvl
            self.store.post(match["room"], uid, "%s %s %s %s — %d pts%s" % (
                user["handle"], verb, title, what, score, " (%+d)" % (new_rating - rating) if new_rating != rating else ""), kind="result")
        out = self._match_out(self.store.match(mid))
        out.update({"rating": new_rating, "rating_change": new_rating - rating, "xp": xp, "progress": arena.level_progress(user["xp"]),
                    "achievements": unlocked, "rank": self.store.rank_of(uid, game)})
        return out

    def _match_out(self, m):
        return {"id": m["id"], "game": m["game"], "outcome": m["outcome"], "score": m["score"], "xp": m["xp"], "rating_change": m["rating_change"]}

    def unlock(self, uid, ids):
        got = []
        for a in ids:
            if a in arena.ACHIEVEMENTS and self.store.grant(uid, a):
                info = arena.ACHIEVEMENTS[a]
                self.store.add_xp(uid, info["xp"])
                self.store.notify(uid, "achievement", "Achievement unlocked: %s" % info["title"], {"id": a})
                got.append(dict(info, id=a))
        return got

    def social_check(self, uid):
        stats = {"friends": len(self.store.friend_ids(uid)), "rooms": self.store.rooms_hosted(uid), "published": self.store.published_by(uid)}
        return self.unlock(uid, arena.social_achievements(stats))

    # ------------------------------------------------------------------
    # Profile
    # ------------------------------------------------------------------

    def profile(self, u, viewer=None):
        out = public_user(u, full=True)
        out["ratings"] = []
        for r in self.store.ratings(u["id"]):
            g = self.store.game(r["game"])
            row = {k: v for k, v in r.items() if k != "user"}
            out["ratings"].append(dict(row, title=g["manifest"]["title"] if g else r["game"], rank=self.store.rank_of(u["id"], r["game"])))
        have = {a["id"]: a["at"] for a in self.store.achievements(u["id"])}
        out["achievements"] = [dict(info, id=k, unlocked=k in have, at=have.get(k)) for k, info in arena.ACHIEVEMENTS.items()]
        out["recent"] = self.store.recent_matches(u["id"], 8)
        out["friends"] = len(self.store.friend_ids(u["id"]))
        out["rooms"] = [self.room_view(r, viewer) for r in self.store.rooms(viewer) if r["host"] == u["id"]][:6]
        if viewer and viewer != u["id"]:
            out["friendship"] = self.store.friend_status(viewer, u["id"])
        return out

    # ------------------------------------------------------------------
    # Forge
    # ------------------------------------------------------------------

    def forge_turn(self, pid, text):
        """Asks the Forge agent, in the background; the person sees the
        reply when it comes (the project's messages)."""
        p = self.store.project(pid)
        history = [m for m in self.store.forge_messages(pid) if m["state"] == "done"]
        self.store.forge_say(pid, "user", text)
        pending = self.store.forge_say(pid, "agent", "", state="thinking")
        if p["status"] == "drafting":
            self.store.update_project(pid, status="building")

        def work():
            try:
                if not self.client.ready:
                    raise forge.ForgeError("the Forge agent is not connected on this server")
                thread = self.threads.get(pid)
                if thread is None:
                    thread = self.client.open_thread("Forge · " + p["title"])
                    self.threads[pid] = thread
                body = forge.brief(self.store.project(pid), [] if thread else history, text, self.cfg["slug"])
                reply = self.client.ask(body, thread)
                self.store.forge_update_message(pending, reply.strip()[:20000], "done")
            except Exception as e:  # noqa: BLE001 — shown to the person
                self.store.forge_update_message(pending, "The Forge could not answer: %s" % e, "failed")
            cur = self.store.project(pid)
            if cur and cur["status"] == "building" and not cur["build"]:
                self.store.update_project(pid, status="drafting")

        threading.Thread(target=work, daemon=True).start()
        return pending

    def forge_build(self, pid, body):
        """tools/arena_forge.py hands over a build: its manifest and folder."""
        p = self.store.project(pid)
        need(p is not None, 404, "no such project")
        m = body.get("manifest") or {}
        problems = arena.validate_manifest(m)
        need(not problems, 422, "; ".join(problems))
        folder = str(body.get("dir") or "")
        need(os.path.isfile(os.path.join(folder, m["pack"])), 422, "the build folder has no %s" % m["pack"])
        other = self.store.game(m["slug"])
        need(other is None or other["author"] == p["user"], 409, "another game already uses the slug %s" % m["slug"])
        dest = os.path.join(self.cfg["data_dir"], "forge", pid, "build", m["slug"])
        if os.path.abspath(folder) != os.path.abspath(dest):
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(folder, dest)
        status = "published" if other and other["status"] == "published" else "testing"
        self.store.upsert_game(m, {"dir": dest}, status, p["user"])
        self.store.update_project(pid, status="ready", slug=m["slug"], build={"version": m["version"], "at": now(), "dir": dest})
        self.store.notify(p["user"], "forge", "%s is built — play-test it, then publish it" % m["title"], {"project": pid, "game": m["slug"]})
        return {"slug": m["slug"], "status": status}

    def forge_publish(self, uid, pid):
        p = self.store.project(pid)
        need(p is not None and p["user"] == uid, 404, "no such project")
        need(p["slug"], 409, "nothing is built yet: ask the Forge to build and submit the game")
        g = self.store.game(p["slug"])
        need(g is not None, 409, "the build is missing")
        need(not arena.validate_manifest(g["manifest"]), 422, "; ".join(arena.validate_manifest(g["manifest"])))
        self.store.upsert_game(g["manifest"], g["files"], "published", uid)
        self.store.update_project(pid, status="published")
        unlocked = self.social_check(uid)
        return {"slug": p["slug"], "status": "published", "achievements": unlocked}


# ----------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------

def handler_for(app):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "AsemanArena/1.0"

        def log_message(self, fmt, *args):
            if not os.environ.get("ARENA_QUIET"):
                super().log_message(fmt, *args)

        # -- helpers ---------------------------------------------------
        def send_json(self, status, obj):
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_file(self, path, cache=False):
            if not os.path.isfile(path):
                raise HTTPError(404, "not found")
            size = os.path.getsize(path)
            ctype = TYPES.get(os.path.splitext(path)[1].lower()) or mimetypes.guess_type(path)[0] or "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "public, max-age=31536000, immutable" if cache else "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(path, "rb") as f:
                shutil.copyfileobj(f, self.wfile, 1 << 20)

        def _drain(self):
            """Reads the whole request body before anything else, so a route
            that ignores it never leaves it in a kept-alive connection."""
            n = int(self.headers.get("Content-Length") or 0)
            if n > 2_000_000:
                self.close_connection = True
                raise HTTPError(413, "request too large")
            self._raw = self.rfile.read(n) if n else b""

        def body(self):
            raw = getattr(self, "_raw", b"")
            if not raw:
                return {}
            try:
                out = json.loads(raw.decode())
            except ValueError:
                raise HTTPError(400, "the body must be JSON")
            need(isinstance(out, dict), 400, "the body must be a JSON object")
            return out

        def me(self, required=True):
            uid = (self.headers.get("X-Aseman-User") or "").strip()
            if not UID.match(uid):
                need(not required, 401, "Sign in to %s to do this" % app.cfg["product"])
                return None
            handle = re.sub(r"[^a-z0-9_.-]", "", (self.headers.get("X-Aseman-User-Handle") or "").lower())[:24]
            return app.store.ensure_user(uid, handle or "player", self.headers.get("X-Aseman-User-Name") or None)

        def internal(self):
            tok = app.cfg.get("internal_token") or ""
            got = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            need(tok and rnd.compare_digest(tok, got), 403, "internal")

        # -- dispatch --------------------------------------------------
        def do_GET(self):
            self.route("GET")

        def do_HEAD(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def do_PUT(self):
            self.route("PUT")

        def do_PATCH(self):
            self.route("PATCH")

        def do_DELETE(self):
            self.route("DELETE")

        def route(self, method):
            u = urlparse(self.path)
            path = unquote(u.path).strip("/")
            q = {k: v[-1] for k, v in parse_qs(u.query).items()}
            try:
                self._drain()
                if path.startswith("api/") or path.startswith("internal/") or path == "healthz":
                    out = self.api(method, path, q)
                    self.send_json(200 if not isinstance(out, tuple) else out[0], out if not isinstance(out, tuple) else out[1])
                else:
                    self.files(path)
            except HTTPError as e:
                self.send_json(e.status, {"error": e.message})
            except BrokenPipeError:
                pass
            except Exception as e:  # noqa: BLE001
                traceback.print_exc()
                self.send_json(500, {"error": "server error: %s" % e})

        def files(self, path):
            if path == "elpian/app.js":
                return self.send_file(ELPIAN)
            if path.startswith("assets/models/"):
                name = os.path.basename(path)
                return self.send_file(os.path.join(PUBLIC, "assets", "models", name), cache=True)
            m = re.match(r"^games/([a-z0-9-]+)/(.+)$", path)
            if m:
                g = app.store.game(m.group(1))
                need(g is not None and g["status"] in ("published", "testing"), 404, "no such game")
                rel = os.path.normpath(m.group(2))
                need(not rel.startswith("..") and not os.path.isabs(rel), 404, "not found")
                if rel == "icon.svg":
                    folder = app.game_dir(g)
                    icon = os.path.join(folder, "icon.svg")
                    return self.send_file(icon if os.path.isfile(icon) else os.path.join(PUBLIC, "icon.svg"), cache=False)
                return self.send_file(os.path.join(app.game_dir(g), rel), cache=rel.endswith(".pck"))
            m = re.match(r"^play/([a-z0-9-]+)$", path)
            if m:
                g = app.store.game(m.group(1))
                need(g is not None and g["status"] == "published" and g["manifest"].get("web"), 404, "no such game")
                self.send_response(302)
                self.send_header("Location", "../games/%s/%s?practice=1" % (g["slug"], g["manifest"]["web"]))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            rel = os.path.normpath(path or "index.html")
            need(not rel.startswith(".."), 404, "not found")
            return self.send_file(os.path.join(PUBLIC, rel))

        def api(self, method, path, q):
            s = app.store
            parts = path.split("/")
            if path == "healthz":
                return {"ok": True, "agent": app.client.ready, "games": len(s.games()), "product": app.cfg["product"]}
            if parts[0] == "internal":
                self.internal()
                if path == "internal/games/sync" and method == "POST":
                    return {"games": app.sync_games()}
                if len(parts) == 4 and parts[1] == "forge" and parts[3] == "build" and method == "POST":
                    return app.forge_build(parts[2], self.body())
                raise HTTPError(404, "no such internal route")
            parts = parts[1:]
            head = parts[0] if parts else ""

            if head == "config" and method == "GET":
                me = self.me(required=False)
                return {"product": app.cfg["product"], "slug": app.cfg["slug"], "asset_base": app.asset_base(),
                        "me": public_user(me, full=True) if me else None, "signed_in": me is not None,
                        "unread": s.unread(me["id"]) if me else None, "room_themes": arena.ROOM_THEMES,
                        "garage_themes": list(arena.GARAGE_THEMES), "achievements": arena.ACHIEVEMENTS,
                        "android_apk": app.cfg.get("android_apk") or "", "forge": app.client.ready}

            # -- me, profiles, people ------------------------------------
            if head == "me":
                me = self.me()
                if method == "GET":
                    return app.profile(me, me["id"])
                if method == "PATCH":
                    b = self.body()
                    fields = {}
                    if "name" in b:
                        name = arena.clean_text(b["name"], 40)
                        need(len(name) >= 2, 400, "a name needs at least 2 characters")
                        fields["name"] = name
                    if "bio" in b:
                        fields["bio"] = arena.clean_text(b["bio"], 280)
                    if "title" in b:
                        fields["title"] = arena.clean_text(b["title"], 40)
                    if "color" in b:
                        need(arena.COLOR.match(str(b["color"])), 400, "color is #rrggbb")
                        fields["color"] = b["color"]
                    if "favorite_game" in b:
                        fields["favorite_game"] = str(b["favorite_game"])[:41]
                    s.update_user(me["id"], fields)
                    return app.profile(s.user(me["id"]), me["id"])
            if head == "profiles" and len(parts) == 2 and method == "GET":
                viewer = self.me(required=False)
                u = s.user_by_handle(parts[1])
                need(u is not None, 404, "no such player")
                return app.profile(u, viewer["id"] if viewer else None)
            if head == "users" and method == "GET":
                self.me()
                return {"users": [public_user(u) for u in s.search_users(q.get("q", ""))]}

            # -- garage ------------------------------------------------------
            if head == "garage":
                me = self.me()
                if method == "PUT":
                    b = self.body()
                    theme = b.get("theme", me["garage_theme"])
                    need(theme in arena.GARAGE_THEMES, 400, "theme is garage or lab")
                    decor = b.get("decor", json.loads(me["garage"] or "{}"))
                    need(isinstance(decor, dict), 400, "decor is an object")
                    s.update_user(me["id"], {"garage_theme": theme, "garage": json.dumps(decor)[:4000]})
                    me = s.user(me["id"])
                have = [a["id"] for a in s.achievements(me["id"])]
                theme = me["garage_theme"]
                return {"theme": theme, "decor": json.loads(me["garage"] or "{}"), "layout": app.garages[theme],
                        "trophies": [dict(arena.ACHIEVEMENTS[a], id=a) for a in have if a in arena.ACHIEVEMENTS],
                        "asset_base": app.asset_base(), "me": public_user(me, full=True), "unread": s.unread(me["id"])}

            # -- store -------------------------------------------------------
            if head == "store":
                viewer = self.me(required=False)
                vid = viewer["id"] if viewer else None
                if len(parts) == 1 and method == "GET":
                    games = s.games("published")
                    if vid:
                        games += [g for g in s.games("testing") if g["author"] == vid]
                    text = q.get("q", "").lower()
                    genre = q.get("genre", "")
                    out = [app.game_view(g, vid) for g in games
                           if (not text or text in g["manifest"]["title"].lower() or text in " ".join(g["manifest"].get("tags", [])))
                           and (not genre or g["manifest"].get("genre") == genre)]
                    return {"games": out, "genres": sorted({g["manifest"].get("genre", "") for g in games} - {""})}
                g = app.visible_game(parts[1], vid)
                need(g is not None, 404, "no such game")
                if len(parts) == 2 and method == "GET":
                    return app.game_view(g, vid, detail=True)
                if len(parts) == 3 and parts[2] == "reviews" and method == "POST":
                    me = self.me()
                    b = self.body()
                    stars = int(b.get("stars") or 0)
                    need(1 <= stars <= 5, 400, "stars is 1 to 5")
                    played = s.one("SELECT 1 AS x FROM matches WHERE user=? AND game=? AND status='done'", (me["id"], g["slug"]))
                    need(played, 403, "play the game before reviewing it")
                    s.review(g["slug"], me["id"], stars, arena.clean_text(b.get("text", ""), 600))
                    return {"rating": s.rating_summary(g["slug"]), "reviews": s.reviews(g["slug"])}

            # -- rooms -------------------------------------------------------
            if head == "rooms":
                viewer = self.me(required=method != "GET")
                vid = viewer["id"] if viewer else None
                if len(parts) == 1:
                    if method == "GET":
                        rooms = s.rooms(vid, mine=q.get("filter") == "mine", game=q.get("game", ""))
                        return {"rooms": [app.room_view(r, vid) for r in rooms]}
                    if method == "POST":
                        b = self.body()
                        name = arena.clean_text(b.get("name", ""), 48)
                        need(len(name) >= 3, 400, "a room needs a name of at least 3 characters")
                        g = app.visible_game(str(b.get("game", "")), vid)
                        need(g is not None, 400, "choose a game from the store")
                        theme = b.get("theme", "arena")
                        need(theme in arena.ROOM_THEMES, 400, "theme is one of " + ", ".join(arena.ROOM_THEMES))
                        vis = b.get("visibility", "public")
                        need(vis in arena.VISIBILITY, 400, "visibility is public, friends or private")
                        need(g["status"] == "published" or vis == "private", 400, "a game still in testing can only be hosted in a private room")
                        mx = max(2, min(64, int(b.get("max_members") or 16)))
                        settings = b.get("settings") if isinstance(b.get("settings"), dict) else {}
                        r = s.create_room(vid, name, g["slug"], theme, vis, arena.clean_text(b.get("description", ""), 200), settings, mx)
                        s.post(r["id"], vid, "%s opened the room" % viewer["handle"], kind="system")
                        app.social_check(vid)
                        return 201, app.room_view(s.room(r["id"]), vid, detail=True)
                r = s.room(parts[1])
                need(r is not None and r["status"] == "open", 404, "no such room")
                need(r["visibility"] == "public" or (vid and s.can_see_room(r, vid)), 404, "no such room")
                rid = r["id"]
                sub = parts[2] if len(parts) > 2 else ""
                if not sub:
                    if method == "GET":
                        return app.room_view(r, vid, detail=True)
                    if method == "PATCH":
                        need(r["host"] == vid, 403, "only the host can change the room")
                        b = self.body()
                        fields = {}
                        if "name" in b:
                            fields["name"] = arena.clean_text(b["name"], 48)
                        if "description" in b:
                            fields["description"] = arena.clean_text(b["description"], 200)
                        if b.get("theme") in arena.ROOM_THEMES:
                            fields["theme"] = b["theme"]
                        if b.get("visibility") in arena.VISIBILITY:
                            fields["visibility"] = b["visibility"]
                        if isinstance(b.get("settings"), dict):
                            fields["settings"] = b["settings"]
                        s.update_room(rid, fields)
                        return app.room_view(s.room(rid), vid, detail=True)
                    if method == "DELETE":
                        need(r["host"] == vid, 403, "only the host can close the room")
                        s.close_room(rid)
                        return {"closed": rid}
                if sub == "join" and method == "POST":
                    need(r["members"] < r["max_members"] or s.is_member(rid, vid), 409, "the room is full")
                    if not s.is_member(rid, vid):
                        s.join_room(rid, vid)
                        s.post(rid, vid, "%s joined" % viewer["handle"], kind="system")
                    return app.room_view(s.room(rid), vid, detail=True)
                if sub == "leave" and method == "POST":
                    need(r["host"] != vid, 409, "the host closes the room instead of leaving it")
                    s.leave_room(rid, vid)
                    s.post(rid, vid, "%s left" % viewer["handle"], kind="system")
                    return {"left": rid}
                if sub == "invite" and method == "POST":
                    need(s.is_member(rid, vid), 403, "join the room first")
                    other = s.user_by_handle(self.body().get("handle", ""))
                    need(other is not None, 404, "no such player")
                    s.notify(other["id"], "invite", "%s invited you to %s" % (viewer["handle"], r["name"]), {"room": rid, "from": viewer["handle"]})
                    return {"invited": other["handle"]}
                if sub == "messages":
                    if method == "GET":
                        return {"messages": s.messages(rid, int(q.get("after") or 0))}
                    if method == "POST":
                        need(s.is_member(rid, vid), 403, "join the room to chat")
                        need(app.chat_limit.ok(vid), 429, "slow down a little")
                        text = arena.clean_text(self.body().get("text", ""))
                        need(text, 400, "say something")
                        mid = s.post(rid, vid, text)
                        return {"id": mid, "messages": s.messages(rid, int(q.get("after") or 0))}
                if sub == "matches" and method == "POST":
                    need(s.is_member(rid, vid), 403, "join the room to play")
                    g = app.visible_game(r["game"], vid)
                    need(g is not None, 409, "the room's game is not in the store any more")
                    return 201, app.launch(vid, g, r, self.body())

            # -- practice matches and results --------------------------------
            if head == "matches":
                if len(parts) == 1 and method == "POST":
                    me = self.me()
                    b = self.body()
                    g = app.visible_game(str(b.get("game", "")), me["id"])
                    need(g is not None, 404, "no such game")
                    return 201, app.launch(me["id"], g, None, b)
                if len(parts) == 3 and parts[2] == "result" and method == "POST":
                    return app.finish(parts[1], self.body())

            # -- leaderboards -------------------------------------------------
            if head == "leaderboard" and method == "GET":
                viewer = self.me(required=False)
                game = q.get("game", "")
                period = q.get("period", "all")
                rows = s.leaderboard(game, period, 50)
                for r in rows:
                    r["level"] = arena.level_for(r.get("xp", 0))
                    r.pop("user", None)  # internal ids stay inside
                out = {"game": game, "period": period, "rows": rows}
                if viewer and game:
                    mine = s.rating(viewer["id"], game)
                    out["me"] = {"rating": {k: v for k, v in mine.items() if k != "user"} if mine else None, "rank": s.rank_of(viewer["id"], game)}
                return out

            # -- friends ------------------------------------------------------
            if head == "friends":
                me = self.me()
                if len(parts) == 1 and method == "GET":
                    f = s.friends(me["id"])
                    return {k: [public_user(u) for u in v] for k, v in f.items()}
                if len(parts) == 1 and method == "POST":
                    other = s.user_by_handle(self.body().get("handle", ""))
                    need(other is not None, 404, "no such player")
                    need(other["id"] != me["id"], 400, "that is you")
                    st = s.request_friend(me["id"], other["id"])
                    if st == "requested":
                        s.notify(other["id"], "friend", "%s wants to be friends" % me["handle"], {"from": me["handle"]})
                    elif st == "friends":
                        s.notify(other["id"], "friend", "%s accepted your friend request" % me["handle"], {"from": me["handle"]})
                        app.social_check(me["id"])
                        app.social_check(other["id"])
                    return {"status": st}
                other = s.user_by_handle(parts[1]) if len(parts) > 1 else None
                need(other is not None, 404, "no such player")
                if len(parts) == 3 and parts[2] == "accept" and method == "POST":
                    need(s.accept_friend(me["id"], other["id"]), 404, "no request from them")
                    s.notify(other["id"], "friend", "%s accepted your friend request" % me["handle"], {"from": me["handle"]})
                    app.social_check(me["id"])
                    app.social_check(other["id"])
                    return {"status": "friends"}
                if len(parts) == 2 and method == "DELETE":
                    s.remove_friend(me["id"], other["id"])
                    return {"status": "none"}

            # -- direct messages ----------------------------------------------
            if head == "messages":
                me = self.me()
                if len(parts) == 1 and method == "GET":
                    return {"threads": [dict(t, user=public_user(t["user"])) for t in s.dm_threads(me["id"])]}
                other = s.user_by_handle(parts[1]) if len(parts) > 1 else None
                need(other is not None, 404, "no such player")
                if method == "GET":
                    return {"with": public_user(other), "messages": dm_rows(s.dm_thread(me["id"], other["id"], int(q.get("after") or 0)), me["id"])}
                if method == "POST":
                    allowed = s.friend_status(me["id"], other["id"]) == "friends" or s.one(
                        "SELECT 1 AS x FROM room_members a JOIN room_members b ON a.room=b.room WHERE a.user=? AND b.user=?", (me["id"], other["id"]))
                    need(allowed, 403, "message friends, or players you share a room with")
                    need(app.chat_limit.ok(me["id"]), 429, "slow down a little")
                    text = arena.clean_text(self.body().get("text", ""), 1000)
                    need(text, 400, "say something")
                    s.send_dm(me["id"], other["id"], text)
                    return {"messages": dm_rows(s.dm_thread(me["id"], other["id"], int(q.get("after") or 0)), me["id"])}

            # -- notifications -------------------------------------------------
            if head == "notifications":
                me = self.me()
                if method == "GET":
                    return {"notifications": s.notifications(me["id"]), "unread": s.unread(me["id"])}
                if method == "POST":
                    s.mark_read(me["id"])
                    return {"unread": s.unread(me["id"])}

            if head == "achievements" and method == "GET":
                return {"achievements": arena.ACHIEVEMENTS}

            if head == "report" and method == "POST":
                me = self.me()
                b = self.body()
                need(b.get("kind") in ("message", "room", "player", "game"), 400, "kind is message, room, player or game")
                s.report(me["id"], b["kind"], str(b.get("target", ""))[:80], arena.clean_text(b.get("reason", ""), 300))
                return {"reported": True}

            # -- forge ---------------------------------------------------------
            if head == "forge":
                me = self.me()
                if len(parts) == 1:
                    if method == "GET":
                        return {"projects": s.projects(me["id"]), "connected": app.client.ready}
                    if method == "POST":
                        b = self.body()
                        title = arena.clean_text(b.get("title", ""), 40)
                        brief = arena.clean_text(b.get("brief", ""), 4000)
                        need(len(title) >= 3, 400, "give the game a working title")
                        need(len(brief) >= 20, 400, "describe the game in a sentence or two")
                        need(len([p for p in s.projects(me["id"]) if p["status"] != "published"]) < 5, 409, "finish or publish a project first (five at a time)")
                        p = s.create_project(me["id"], title, brief, arena.clean_text(b.get("genre", ""), 30))
                        app.forge_turn(p["id"], brief)
                        return 201, {"project": s.project(p["id"]), "messages": s.forge_messages(p["id"])}
                p = s.project(parts[1])
                need(p is not None and p["user"] == me["id"], 404, "no such project")
                if len(parts) == 2 and method == "GET":
                    out = {"project": p, "messages": s.forge_messages(p["id"])}
                    if p["slug"]:
                        g = s.game(p["slug"])
                        out["game"] = app.game_view(g, me["id"]) if g else None
                    return out
                if len(parts) == 3 and parts[2] == "messages" and method == "POST":
                    msgs = s.forge_messages(p["id"])
                    need(not any(m["state"] == "thinking" for m in msgs), 409, "the Forge is still working on your last message")
                    text = arena.clean_text(self.body().get("text", ""), 4000)
                    need(text, 400, "say something")
                    app.forge_turn(p["id"], text)
                    return {"project": s.project(p["id"]), "messages": s.forge_messages(p["id"])}
                if len(parts) == 3 and parts[2] == "publish" and method == "POST":
                    return app.forge_publish(me["id"], p["id"])
            raise HTTPError(404 if method == "GET" else 405, "no such route: %s %s" % (method, path))

    return Handler


def main():
    app = App()
    srv = ThreadingHTTPServer(("0.0.0.0", app.cfg["port"]), handler_for(app))
    srv.daemon_threads = True
    print("%s on :%d (games: %s; forge agent: %s)" % (app.cfg["product"], app.cfg["port"], ", ".join(g["slug"] for g in app.store.games()) or "none",
                                                      "connected" if app.client.ready else "not connected"), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
