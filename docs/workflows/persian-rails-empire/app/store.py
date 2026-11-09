"""SQLite persistence for Persian Rails Empire."""

import json
import os
import sqlite3
import threading
import time
import uuid

import rails


SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  handle TEXT UNIQUE,
  name TEXT,
  rating INTEGER DEFAULT 1200,
  xp INTEGER DEFAULT 0,
  wins INTEGER DEFAULT 0,
  losses INTEGER DEFAULT 0,
  draws INTEGER DEFAULT 0,
  created_at REAL
);
CREATE TABLE IF NOT EXISTS matches (
  id TEXT PRIMARY KEY,
  user_id TEXT,
  token TEXT UNIQUE,
  level INTEGER,
  status TEXT,
  created_at REAL,
  finished_at REAL,
  result_json TEXT
);
CREATE TABLE IF NOT EXISTS ratings_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT,
  match_id TEXT,
  rating_before INTEGER,
  rating_after INTEGER,
  created_at REAL
);
"""


class Store:
    def __init__(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, "rails.db")
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(self.path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        with self.lock:
            self.conn.executescript(SCHEMA)
            self.conn.commit()

    def _q(self, sql, args=(), one=False):
        with self.lock:
            cur = self.conn.execute(sql, args)
            if sql.strip().upper().startswith("SELECT"):
                rows = cur.fetchall()
                return rows[0] if one and rows else (None if one else rows)
            self.conn.commit()
            return cur

    def ensure_user(self, uid, handle=None, name=None):
        row = self._q("SELECT * FROM users WHERE id=?", (uid,), one=True)
        if row:
            return dict(row)
        handle = handle or ("u_" + uid[:8])
        name = rails.sanitize_name(name or "مسافر ریلی")
        self._q(
            "INSERT INTO users (id, handle, name, rating, xp, wins, losses, draws, created_at) VALUES (?,?,?,?,0,0,0,0,?)",
            (uid, handle, name, rails.START_RATING, time.time()),
        )
        return dict(self._q("SELECT * FROM users WHERE id=?", (uid,), one=True))

    def patch_user(self, uid, name=None):
        u = self.ensure_user(uid)
        if name:
            self._q("UPDATE users SET name=? WHERE id=?", (rails.sanitize_name(name), uid))
        return dict(self._q("SELECT * FROM users WHERE id=?", (uid,), one=True))

    def start_match(self, uid, level=2):
        self.ensure_user(uid)
        mid = "m_" + uuid.uuid4().hex[:12]
        token = uuid.uuid4().hex
        self._q(
            "INSERT INTO matches (id, user_id, token, level, status, created_at) VALUES (?,?,?,?,?,?)",
            (mid, uid, token, int(level), "open", time.time()),
        )
        return {"id": mid, "token": token, "level": int(level), "game": "persian-rails"}

    def finish_match(self, token, body):
        row = self._q("SELECT * FROM matches WHERE token=?", (token,), one=True)
        if not row:
            return None, "unknown match"
        if row["status"] != "open":
            return None, "already finished"
        level = int(row["level"])
        elapsed = time.time() - float(row["created_at"])
        ok, why = rails.believable_result(body, level, elapsed)
        if not ok:
            return None, why
        uid = row["user_id"]
        user = dict(self._q("SELECT * FROM users WHERE id=?", (uid,), one=True))
        before = int(user["rating"])
        ai_r = rails.AI_RATING.get(level, 1200)
        after = rails.elo(before, ai_r, rails.outcome_score(body["outcome"]))
        xp = int(user["xp"]) + rails.xp_for_result(body["outcome"], level)
        wins = int(user["wins"]) + (1 if body["outcome"] == "win" else 0)
        losses = int(user["losses"]) + (1 if body["outcome"] == "loss" else 0)
        draws = int(user["draws"]) + (1 if body["outcome"] == "draw" else 0)
        self._q(
            "UPDATE users SET rating=?, xp=?, wins=?, losses=?, draws=? WHERE id=?",
            (after, xp, wins, losses, draws, uid),
        )
        self._q(
            "UPDATE matches SET status=?, finished_at=?, result_json=? WHERE id=?",
            ("done", time.time(), json.dumps(body, ensure_ascii=False), row["id"]),
        )
        self._q(
            "INSERT INTO ratings_log (user_id, match_id, rating_before, rating_after, created_at) VALUES (?,?,?,?,?)",
            (uid, row["id"], before, after, time.time()),
        )
        progress = rails.level_from_xp(xp)
        return {
            "match": row["id"],
            "rating_before": before,
            "rating_after": after,
            "xp": xp,
            "progress": progress,
            "outcome": body["outcome"],
        }, None

    def leaderboard(self, limit=20):
        rows = self._q(
            "SELECT handle, name, rating, wins, losses, draws, xp FROM users ORDER BY rating DESC, wins DESC LIMIT ?",
            (int(limit),),
        )
        return [dict(r) for r in rows]

    def public_user(self, u):
        if not u:
            return None
        progress = rails.level_from_xp(int(u["xp"]))
        return {
            "id": u["id"],
            "handle": u["handle"],
            "name": u["name"],
            "rating": u["rating"],
            "wins": u["wins"],
            "losses": u["losses"],
            "draws": u["draws"],
            "xp": u["xp"],
            "progress": progress,
        }
