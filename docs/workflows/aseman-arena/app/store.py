"""Aseman Arena's records, in one SQLite database under the data folder
(kept across reinstalls): people and their garages, games in the store and
their reviews, rooms with members and chat, matches, ratings, achievements,
friends, direct messages, notifications, the Forge's projects and reports.

Every method takes and returns plain dicts. One connection per thread,
WAL, foreign keys on; writes go through one lock.
"""

import json
import os
import secrets
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY, handle TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
  bio TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT '#6aa8ff', title TEXT NOT NULL DEFAULT '',
  garage_theme TEXT NOT NULL DEFAULT 'garage', garage TEXT NOT NULL DEFAULT '{}',
  favorite_game TEXT NOT NULL DEFAULT '', xp INTEGER NOT NULL DEFAULT 0,
  matches INTEGER NOT NULL DEFAULT 0, wins INTEGER NOT NULL DEFAULT 0, streak INTEGER NOT NULL DEFAULT 0,
  best_streak INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, last_seen REAL NOT NULL);
CREATE TABLE IF NOT EXISTS games (
  slug TEXT PRIMARY KEY, manifest TEXT NOT NULL, status TEXT NOT NULL, author TEXT NOT NULL DEFAULT '',
  official INTEGER NOT NULL DEFAULT 0, version TEXT NOT NULL, files TEXT NOT NULL,
  plays INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS reviews (
  game TEXT NOT NULL, user TEXT NOT NULL, stars INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '', at REAL NOT NULL,
  PRIMARY KEY (game, user));
CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, game TEXT NOT NULL, theme TEXT NOT NULL, visibility TEXT NOT NULL,
  host TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', settings TEXT NOT NULL DEFAULT '{}',
  max_members INTEGER NOT NULL DEFAULT 16, status TEXT NOT NULL DEFAULT 'open', created_at REAL NOT NULL, last_active REAL NOT NULL);
CREATE TABLE IF NOT EXISTS room_members (
  room TEXT NOT NULL, user TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'member', joined_at REAL NOT NULL,
  PRIMARY KEY (room, user));
CREATE TABLE IF NOT EXISTS room_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, room TEXT NOT NULL, user TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'chat',
  text TEXT NOT NULL, at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS matches (
  id TEXT PRIMARY KEY, token TEXT NOT NULL, user TEXT NOT NULL, game TEXT NOT NULL, room TEXT NOT NULL DEFAULT '',
  settings TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'playing', result TEXT NOT NULL DEFAULT '{}',
  outcome TEXT NOT NULL DEFAULT '', score INTEGER NOT NULL DEFAULT 0, xp INTEGER NOT NULL DEFAULT 0,
  rating_change INTEGER NOT NULL DEFAULT 0, started_at REAL NOT NULL, ended_at REAL);
CREATE TABLE IF NOT EXISTS ratings (
  user TEXT NOT NULL, game TEXT NOT NULL, rating INTEGER NOT NULL, best_score INTEGER NOT NULL DEFAULT 0,
  games INTEGER NOT NULL DEFAULT 0, wins INTEGER NOT NULL DEFAULT 0, draws INTEGER NOT NULL DEFAULT 0,
  week_score INTEGER NOT NULL DEFAULT 0, week TEXT NOT NULL DEFAULT '', PRIMARY KEY (user, game));
CREATE TABLE IF NOT EXISTS achievements (
  user TEXT NOT NULL, id TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY (user, id));
CREATE TABLE IF NOT EXISTS friends (
  a TEXT NOT NULL, b TEXT NOT NULL, status TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY (a, b));
CREATE TABLE IF NOT EXISTS dms (
  id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL, recipient TEXT NOT NULL, text TEXT NOT NULL,
  at REAL NOT NULL, read INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS notifications (
  id INTEGER PRIMARY KEY AUTOINCREMENT, user TEXT NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '{}', at REAL NOT NULL, read INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS forge_projects (
  id TEXT PRIMARY KEY, user TEXT NOT NULL, title TEXT NOT NULL, brief TEXT NOT NULL, genre TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'drafting', slug TEXT NOT NULL DEFAULT '', build TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS forge_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, project TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'done', at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT, user TEXT NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL,
  reason TEXT NOT NULL, at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS room_messages_room ON room_messages (room, id);
CREATE INDEX IF NOT EXISTS matches_user ON matches (user, started_at);
CREATE INDEX IF NOT EXISTS dms_pair ON dms (sender, recipient, id);
CREATE INDEX IF NOT EXISTS notifications_user ON notifications (user, id);
"""


def now():
    return time.time()


def week_of(t=None):
    return time.strftime("%G-W%V", time.gmtime(t or now()))


def new_id(prefix):
    return prefix + "_" + secrets.token_hex(6)


class Store:
    def __init__(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, "arena.db")
        self.lock = threading.RLock()
        self._local = threading.local()
        with self.lock:
            c = self.db()
            c.executescript(SCHEMA)
            c.commit()

    def db(self):
        c = getattr(self._local, "c", None)
        if c is None:
            c = sqlite3.connect(self.path, timeout=15, check_same_thread=False)
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("PRAGMA foreign_keys=ON")
            self._local.c = c
        return c

    def q(self, sql, args=()):
        return [dict(r) for r in self.db().execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        r = self.db().execute(sql, args).fetchone()
        return dict(r) if r else None

    def x(self, sql, args=()):
        with self.lock:
            c = self.db()
            cur = c.execute(sql, args)
            c.commit()
            return cur

    # ------------------------------------------------------------------
    # People
    # ------------------------------------------------------------------

    def ensure_user(self, uid, handle, name=None):
        """The person behind a request, made on their first visit and seen
        now. Handles are unique: a clash gets a suffix."""
        u = self.user(uid)
        t = now()
        if u:
            if t - u["last_seen"] > 20:
                self.x("UPDATE users SET last_seen=? WHERE id=?", (t, uid))
                u["last_seen"] = t
            return u
        base = (handle or "player").lower()[:24] or "player"
        h, n = base, 1
        while self.one("SELECT 1 AS x FROM users WHERE handle=?", (h,)):
            n += 1
            h = "%s%d" % (base, n)
        palette = ["#6aa8ff", "#ff9a5c", "#5ce1c2", "#ffd166", "#c38bff", "#ff6b8b"]
        color = palette[sum(map(ord, uid)) % len(palette)]
        self.x("INSERT INTO users (id, handle, name, color, created_at, last_seen) VALUES (?,?,?,?,?,?)",
               (uid, h, name or handle or h, color, t, t))
        return self.user(uid)

    def user(self, uid):
        return self.one("SELECT * FROM users WHERE id=?", (uid,))

    def user_by_handle(self, handle):
        return self.one("SELECT * FROM users WHERE handle=?", (str(handle or "").lower(),))

    def update_user(self, uid, fields):
        allowed = {"name", "bio", "color", "title", "garage_theme", "garage", "favorite_game"}
        sets = {k: v for k, v in fields.items() if k in allowed}
        if not sets:
            return self.user(uid)
        cols = ", ".join("%s=?" % k for k in sets)
        self.x("UPDATE users SET %s WHERE id=?" % cols, tuple(sets.values()) + (uid,))
        return self.user(uid)

    def search_users(self, text, limit=20):
        like = "%" + str(text).lower().replace("%", "") + "%"
        return self.q("SELECT * FROM users WHERE handle LIKE ? OR lower(name) LIKE ? ORDER BY last_seen DESC LIMIT ?", (like, like, limit))

    # ------------------------------------------------------------------
    # Games and the store
    # ------------------------------------------------------------------

    def upsert_game(self, manifest, files, status="published", author="", official=False):
        slug = manifest["slug"]
        t = now()
        old = self.game(slug)
        if old:
            self.x("UPDATE games SET manifest=?, files=?, version=?, status=?, updated_at=? WHERE slug=?",
                   (json.dumps(manifest), json.dumps(files), manifest["version"], status, t, slug))
        else:
            self.x("INSERT INTO games (slug, manifest, status, author, official, version, files, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                   (slug, json.dumps(manifest), status, author, 1 if official else 0, manifest["version"], json.dumps(files), t, t))
        return self.game(slug)

    def game(self, slug):
        g = self.one("SELECT * FROM games WHERE slug=?", (slug,))
        if g:
            g["manifest"] = json.loads(g["manifest"])
            g["files"] = json.loads(g["files"])
        return g

    def games(self, status="published"):
        out = []
        for g in self.q("SELECT * FROM games WHERE status=? ORDER BY official DESC, plays DESC, created_at", (status,)):
            g["manifest"] = json.loads(g["manifest"])
            g["files"] = json.loads(g["files"])
            out.append(g)
        return out

    def review(self, game, uid, stars, text):
        self.x("INSERT INTO reviews (game, user, stars, text, at) VALUES (?,?,?,?,?) ON CONFLICT(game, user) DO UPDATE SET stars=excluded.stars, text=excluded.text, at=excluded.at",
               (game, uid, stars, text, now()))

    def reviews(self, game, limit=20):
        return self.q("SELECT r.game, r.stars, r.text, r.at, u.handle, u.name, u.color FROM reviews r JOIN users u ON u.id=r.user WHERE game=? ORDER BY at DESC LIMIT ?", (game, limit))

    def rating_summary(self, game):
        r = self.one("SELECT COUNT(*) AS n, AVG(stars) AS avg FROM reviews WHERE game=?", (game,))
        return {"count": r["n"], "average": round(r["avg"] or 0, 2)}

    # ------------------------------------------------------------------
    # Rooms
    # ------------------------------------------------------------------

    def create_room(self, host, name, game, theme, visibility, description, settings, max_members):
        rid = new_id("room")
        t = now()
        self.x("INSERT INTO rooms (id, name, game, theme, visibility, host, description, settings, max_members, created_at, last_active) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
               (rid, name, game, theme, visibility, host, description, json.dumps(settings), max_members, t, t))
        self.x("INSERT INTO room_members (room, user, role, joined_at) VALUES (?,?,?,?)", (rid, host, "host", t))
        return self.room(rid)

    def room(self, rid):
        r = self.one("SELECT r.*, u.handle AS host_handle, u.name AS host_name, (SELECT COUNT(*) FROM room_members m WHERE m.room=r.id) AS members FROM rooms r JOIN users u ON u.id=r.host WHERE r.id=?", (rid,))
        if r:
            r["settings"] = json.loads(r["settings"])
        return r

    def rooms(self, viewer=None, mine=False, game="", limit=60):
        friends = set(self.friend_ids(viewer)) if viewer else set()
        sql = ("SELECT r.*, u.handle AS host_handle, u.name AS host_name, (SELECT COUNT(*) FROM room_members m WHERE m.room=r.id) AS members, "
               "(SELECT COUNT(*) FROM room_members m JOIN users mu ON mu.id=m.user WHERE m.room=r.id AND mu.last_seen>?) AS online, "
               "EXISTS(SELECT 1 FROM room_members m WHERE m.room=r.id AND m.user=?) AS joined "
               "FROM rooms r JOIN users u ON u.id=r.host WHERE r.status='open'")
        args = [now() - 120, viewer or ""]
        if game:
            sql += " AND r.game=?"
            args.append(game)
        sql += " ORDER BY r.last_active DESC LIMIT ?"
        args.append(limit * 3)
        out = []
        for r in self.q(sql, args):
            r["settings"] = json.loads(r["settings"])
            r["joined"] = bool(r["joined"])
            if mine and not r["joined"]:
                continue
            if r["visibility"] == "private" and not r["joined"]:
                continue
            if r["visibility"] == "friends" and not r["joined"] and r["host"] not in friends:
                continue
            out.append(r)
        return out[:limit]

    def can_see_room(self, room, uid):
        if room["visibility"] == "public" or self.is_member(room["id"], uid):
            return True
        if room["visibility"] == "friends":
            return room["host"] in self.friend_ids(uid)
        return bool(self.one("SELECT 1 AS x FROM notifications WHERE user=? AND kind='invite' AND json_extract(data,'$.room')=?", (uid, room["id"])))

    def is_member(self, rid, uid):
        return bool(self.one("SELECT 1 AS x FROM room_members WHERE room=? AND user=?", (rid, uid)))

    def join_room(self, rid, uid):
        self.x("INSERT OR IGNORE INTO room_members (room, user, role, joined_at) VALUES (?,?,?,?)", (rid, uid, "member", now()))
        self.touch_room(rid)

    def leave_room(self, rid, uid):
        self.x("DELETE FROM room_members WHERE room=? AND user=?", (rid, uid))

    def close_room(self, rid):
        self.x("UPDATE rooms SET status='closed' WHERE id=?", (rid,))

    def update_room(self, rid, fields):
        allowed = {"name", "description", "theme", "visibility", "settings", "max_members"}
        sets = {k: (json.dumps(v) if k == "settings" else v) for k, v in fields.items() if k in allowed}
        if sets:
            self.x("UPDATE rooms SET %s WHERE id=?" % ", ".join("%s=?" % k for k in sets), tuple(sets.values()) + (rid,))
        return self.room(rid)

    def touch_room(self, rid):
        self.x("UPDATE rooms SET last_active=? WHERE id=?", (now(), rid))

    def members(self, rid):
        return self.q("SELECT u.id, u.handle, u.name, u.color, u.xp, u.last_seen, m.role, m.joined_at FROM room_members m JOIN users u ON u.id=m.user WHERE m.room=? ORDER BY m.role='host' DESC, m.joined_at", (rid,))

    def post(self, rid, uid, text, kind="chat"):
        cur = self.x("INSERT INTO room_messages (room, user, kind, text, at) VALUES (?,?,?,?,?)", (rid, uid, kind, text, now()))
        self.touch_room(rid)
        return cur.lastrowid

    def messages(self, rid, after=0, limit=80):
        rows = self.q("SELECT m.id, m.room, m.kind, m.text, m.at, u.handle, u.name, u.color FROM room_messages m JOIN users u ON u.id=m.user WHERE m.room=? AND m.id>? ORDER BY m.id DESC LIMIT ?", (rid, after, limit))
        return list(reversed(rows))

    def rooms_hosted(self, uid):
        return self.one("SELECT COUNT(*) AS n FROM rooms WHERE host=?", (uid,))["n"]

    # ------------------------------------------------------------------
    # Matches, ratings, achievements
    # ------------------------------------------------------------------

    def start_match(self, uid, game, room, settings):
        mid = new_id("m")
        token = secrets.token_urlsafe(24)
        self.x("INSERT INTO matches (id, token, user, game, room, settings, started_at) VALUES (?,?,?,?,?,?,?)",
               (mid, token, uid, game, room or "", json.dumps(settings), now()))
        self.x("UPDATE games SET plays=plays+1 WHERE slug=?", (game,))
        return self.match(mid)

    def match(self, mid):
        m = self.one("SELECT * FROM matches WHERE id=?", (mid,))
        if m:
            m["settings"] = json.loads(m["settings"])
            m["result"] = json.loads(m["result"])
        return m

    def finish_match(self, mid, result, outcome, score, xp, rating_change):
        self.x("UPDATE matches SET status='done', result=?, outcome=?, score=?, xp=?, rating_change=?, ended_at=? WHERE id=? AND status='playing'",
               (json.dumps(result), outcome, score, xp, rating_change, now(), mid))

    def recent_matches(self, uid, limit=10):
        rows = self.q("SELECT m.id, m.game, m.room, m.outcome, m.score, m.xp, m.rating_change, m.started_at, m.ended_at, m.settings FROM matches m WHERE m.user=? AND m.status='done' ORDER BY m.ended_at DESC LIMIT ?", (uid, limit))
        for r in rows:
            r["settings"] = json.loads(r["settings"])
        return rows

    def rating(self, uid, game):
        return self.one("SELECT * FROM ratings WHERE user=? AND game=?", (uid, game))

    def ratings(self, uid):
        return self.q("SELECT * FROM ratings WHERE user=?", (uid,))

    def save_rating(self, uid, game, rating, score, outcome):
        week = week_of()
        r = self.rating(uid, game)
        if not r:
            self.x("INSERT INTO ratings (user, game, rating, best_score, games, wins, draws, week_score, week) VALUES (?,?,?,?,?,?,?,?,?)",
                   (uid, game, rating, score, 1, 1 if outcome == "win" else 0, 1 if outcome == "draw" else 0, score, week))
        else:
            ws = (r["week_score"] if r["week"] == week else 0) + score
            self.x("UPDATE ratings SET rating=?, best_score=max(best_score, ?), games=games+1, wins=wins+?, draws=draws+?, week_score=?, week=? WHERE user=? AND game=?",
                   (rating, score, 1 if outcome == "win" else 0, 1 if outcome == "draw" else 0, ws, week, uid, game))
        return self.rating(uid, game)

    def record_result_stats(self, uid, outcome, xp):
        u = self.user(uid)
        streak = u["streak"] + 1 if outcome == "win" else 0
        self.x("UPDATE users SET xp=xp+?, matches=matches+1, wins=wins+?, streak=?, best_streak=max(best_streak, ?) WHERE id=?",
               (xp, 1 if outcome == "win" else 0, streak, streak, uid))
        return self.user(uid)

    def add_xp(self, uid, xp):
        self.x("UPDATE users SET xp=xp+? WHERE id=?", (xp, uid))

    def leaderboard(self, game="", period="all", limit=50):
        if not game:
            rows = self.q("SELECT id AS user, handle, name, color, xp, matches, wins, title FROM users WHERE matches>0 AND id NOT LIKE 'system:%' ORDER BY xp DESC, wins DESC LIMIT ?", (limit,))
        elif period == "week":
            rows = self.q("SELECT r.*, u.handle, u.name, u.color, u.xp, u.title FROM ratings r JOIN users u ON u.id=r.user WHERE r.game=? AND r.week=? AND r.user NOT LIKE 'system:%' ORDER BY r.week_score DESC LIMIT ?", (game, week_of(), limit))
        else:
            order = "r.rating DESC, r.wins DESC" if game == "arena-chess" else "r.best_score DESC, r.wins DESC"
            rows = self.q("SELECT r.*, u.handle, u.name, u.color, u.xp, u.title FROM ratings r JOIN users u ON u.id=r.user WHERE r.game=? AND r.user NOT LIKE 'system:%%' ORDER BY %s LIMIT ?" % order, (game, limit))
        for i, r in enumerate(rows):
            r["rank"] = i + 1
            r.pop("user", None)  # people are known by handle outside
        return rows

    def rank_of(self, uid, game):
        r = self.rating(uid, game)
        if not r:
            return None
        if game == "arena-chess":
            n = self.one("SELECT COUNT(*) AS n FROM ratings WHERE game=? AND rating>?", (game, r["rating"]))["n"]
        else:
            n = self.one("SELECT COUNT(*) AS n FROM ratings WHERE game=? AND best_score>?", (game, r["best_score"]))["n"]
        return n + 1

    def grant(self, uid, ach):
        cur = self.x("INSERT OR IGNORE INTO achievements (user, id, at) VALUES (?,?,?)", (uid, ach, now()))
        return cur.rowcount > 0

    def achievements(self, uid):
        return self.q("SELECT id, at FROM achievements WHERE user=? ORDER BY at", (uid,))

    def room_board(self, rid, limit=10):
        return self.q("SELECT u.handle, u.name, u.color, MAX(m.score) AS best, COUNT(*) AS games, SUM(m.outcome='win') AS wins FROM matches m JOIN users u ON u.id=m.user WHERE m.room=? AND m.status='done' GROUP BY m.user ORDER BY best DESC LIMIT ?", (rid, limit))

    # ------------------------------------------------------------------
    # Friends, direct messages, notifications
    # ------------------------------------------------------------------

    def friend_status(self, a, b):
        r = self.one("SELECT status, a FROM friends WHERE (a=? AND b=?) OR (a=? AND b=?)", (a, b, b, a))
        if not r:
            return "none"
        if r["status"] == "accepted":
            return "friends"
        return "requested" if r["a"] == a else "incoming"

    def request_friend(self, a, b):
        st = self.friend_status(a, b)
        if st == "incoming":
            self.x("UPDATE friends SET status='accepted', at=? WHERE a=? AND b=?", (now(), b, a))
            return "friends"
        if st == "none":
            self.x("INSERT INTO friends (a, b, status, at) VALUES (?,?,?,?)", (a, b, "pending", now()))
            return "requested"
        return st

    def accept_friend(self, me, other):
        cur = self.x("UPDATE friends SET status='accepted', at=? WHERE a=? AND b=? AND status='pending'", (now(), other, me))
        return cur.rowcount > 0

    def remove_friend(self, a, b):
        self.x("DELETE FROM friends WHERE (a=? AND b=?) OR (a=? AND b=?)", (a, b, b, a))

    def friend_ids(self, uid):
        rows = self.q("SELECT a, b FROM friends WHERE (a=? OR b=?) AND status='accepted'", (uid, uid))
        return [r["b"] if r["a"] == uid else r["a"] for r in rows]

    def friends(self, uid):
        out = []
        for fid in self.friend_ids(uid):
            u = self.user(fid)
            if u:
                out.append(u)
        incoming = self.q("SELECT u.* FROM friends f JOIN users u ON u.id=f.a WHERE f.b=? AND f.status='pending'", (uid,))
        outgoing = self.q("SELECT u.* FROM friends f JOIN users u ON u.id=f.b WHERE f.a=? AND f.status='pending'", (uid,))
        return {"friends": out, "incoming": incoming, "outgoing": outgoing}

    def send_dm(self, sender, recipient, text):
        cur = self.x("INSERT INTO dms (sender, recipient, text, at) VALUES (?,?,?,?)", (sender, recipient, text, now()))
        return cur.lastrowid

    def dm_thread(self, a, b, after=0, limit=80):
        rows = self.q("SELECT * FROM dms WHERE ((sender=? AND recipient=?) OR (sender=? AND recipient=?)) AND id>? ORDER BY id DESC LIMIT ?", (a, b, b, a, after, limit))
        self.x("UPDATE dms SET read=1 WHERE sender=? AND recipient=?", (b, a))
        return list(reversed(rows))

    def dm_threads(self, uid):
        rows = self.q("SELECT CASE WHEN sender=? THEN recipient ELSE sender END AS other, MAX(id) AS last_id, SUM(CASE WHEN recipient=? AND read=0 THEN 1 ELSE 0 END) AS unread FROM dms WHERE sender=? OR recipient=? GROUP BY other ORDER BY last_id DESC LIMIT 50", (uid, uid, uid, uid))
        out = []
        for r in rows:
            u = self.user(r["other"])
            last = self.one("SELECT text, at, sender=? AS mine FROM dms WHERE id=?", (uid, r["last_id"]))
            if u:
                out.append({"user": u, "last": last, "unread": r["unread"]})
        return out

    def notify(self, uid, kind, text, data=None):
        self.x("INSERT INTO notifications (user, kind, text, data, at) VALUES (?,?,?,?,?)", (uid, kind, text, json.dumps(data or {}), now()))

    def notifications(self, uid, limit=40):
        rows = self.q("SELECT * FROM notifications WHERE user=? ORDER BY id DESC LIMIT ?", (uid, limit))
        for r in rows:
            r["data"] = json.loads(r["data"])
        return rows

    def unread(self, uid):
        n = self.one("SELECT COUNT(*) AS n FROM notifications WHERE user=? AND read=0", (uid,))["n"]
        d = self.one("SELECT COUNT(*) AS n FROM dms WHERE recipient=? AND read=0", (uid,))["n"]
        return {"notifications": n, "messages": d}

    def mark_read(self, uid):
        self.x("UPDATE notifications SET read=1 WHERE user=?", (uid,))

    # ------------------------------------------------------------------
    # The Forge
    # ------------------------------------------------------------------

    def create_project(self, uid, title, brief, genre):
        pid = new_id("fp")
        t = now()
        self.x("INSERT INTO forge_projects (id, user, title, brief, genre, created_at, updated_at) VALUES (?,?,?,?,?,?,?)", (pid, uid, title, brief, genre, t, t))
        return self.project(pid)

    def project(self, pid):
        p = self.one("SELECT * FROM forge_projects WHERE id=?", (pid,))
        if p:
            p["build"] = json.loads(p["build"])
        return p

    def projects(self, uid):
        rows = self.q("SELECT * FROM forge_projects WHERE user=? ORDER BY updated_at DESC", (uid,))
        for r in rows:
            r["build"] = json.loads(r["build"])
        return rows

    def update_project(self, pid, **fields):
        if "build" in fields:
            fields["build"] = json.dumps(fields["build"])
        fields["updated_at"] = now()
        self.x("UPDATE forge_projects SET %s WHERE id=?" % ", ".join("%s=?" % k for k in fields), tuple(fields.values()) + (pid,))
        return self.project(pid)

    def forge_say(self, pid, role, text, state="done"):
        cur = self.x("INSERT INTO forge_messages (project, role, text, state, at) VALUES (?,?,?,?,?)", (pid, role, text, state, now()))
        self.x("UPDATE forge_projects SET updated_at=? WHERE id=?", (now(), pid))
        return cur.lastrowid

    def forge_update_message(self, mid, text, state):
        self.x("UPDATE forge_messages SET text=?, state=? WHERE id=?", (text, state, mid))

    def forge_messages(self, pid):
        return self.q("SELECT * FROM forge_messages WHERE project=? ORDER BY id", (pid,))

    def published_by(self, uid):
        return self.one("SELECT COUNT(*) AS n FROM games WHERE author=? AND status='published'", (uid,))["n"]

    def report(self, uid, kind, target, reason):
        self.x("INSERT INTO reports (user, kind, target, reason, at) VALUES (?,?,?,?,?)", (uid, kind, target, reason, now()))
