"""Chats and their messages, per person, in SQLite on the project's disk.

The computer sleeps and wakes with nothing running, so a conversation lives in
a file, never only in memory. Every query is scoped by the platform's person id
(`X-Decillion-User`): one person never reads another's chats.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

SCHEMA = """
create table if not exists chats(
  id text primary key, user text not null, title text not null,
  created real not null, updated real not null, memory text not null default '[]');
create index if not exists chats_user on chats(user, updated desc);
create table if not exists messages(
  id text primary key, chat_id text not null references chats(id) on delete cascade,
  role text not null, text text not null, payload text not null default '{}', created real not null);
create index if not exists messages_chat on messages(chat_id, created);
"""

HISTORY_TURNS = 20  # the platform uses the latest 20 messages of `history`


class Store:
    def __init__(self, path: str | Path) -> None:
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("pragma foreign_keys = on")
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)

    def _run(self, sql: str, *args: Any) -> list[sqlite3.Row]:
        with self._lock:
            cur = self._db.execute(sql, args)
            rows = cur.fetchall()
            self._db.commit()
            return rows

    # -- chats ------------------------------------------------------------
    def create_chat(self, user: str, title: str = "") -> dict[str, Any]:
        cid, now = uuid.uuid4().hex[:12], time.time()
        self._run("insert into chats(id,user,title,created,updated) values (?,?,?,?,?)", cid, user, title or "New chat", now, now)
        return self.get_chat(user, cid)  # type: ignore[return-value]

    def get_chat(self, user: str, chat_id: str) -> dict[str, Any] | None:
        rows = self._run("select * from chats where id=? and user=?", chat_id, user)
        if not rows:
            return None
        r = rows[0]
        return {"id": r["id"], "title": r["title"], "created": r["created"], "updated": r["updated"],
                "memory": json.loads(r["memory"])}

    def list_chats(self, user: str, limit: int = 50) -> list[dict[str, Any]]:
        return [{"id": r["id"], "title": r["title"], "updated": r["updated"]}
                for r in self._run("select id,title,updated from chats where user=? order by updated desc limit ?", user, limit)]

    def delete_chat(self, user: str, chat_id: str) -> bool:
        return bool(self._run("delete from chats where id=? and user=? returning id", chat_id, user))

    def rename(self, user: str, chat_id: str, title: str) -> None:
        self._run("update chats set title=? where id=? and user=?", title[:80], chat_id, user)

    def remember(self, user: str, chat_id: str, entry: dict[str, Any], keep: int = 8) -> None:
        chat = self.get_chat(user, chat_id)
        if chat is None:
            return
        memory = (chat["memory"] + [entry])[-keep:]
        self._run("update chats set memory=? where id=? and user=?", json.dumps(memory, ensure_ascii=False), chat_id, user)

    # -- messages ---------------------------------------------------------
    def add_message(self, user: str, chat_id: str, role: str, text: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        if self.get_chat(user, chat_id) is None:
            raise KeyError("no such chat")
        mid, now = uuid.uuid4().hex[:12], time.time()
        self._run("insert into messages(id,chat_id,role,text,payload,created) values (?,?,?,?,?,?)",
                  mid, chat_id, role, text, json.dumps(payload or {}, ensure_ascii=False), now)
        self._run("update chats set updated=? where id=?", now, chat_id)
        return {"id": mid, "role": role, "text": text, "payload": payload or {}, "created": now}

    def messages(self, user: str, chat_id: str) -> list[dict[str, Any]]:
        if self.get_chat(user, chat_id) is None:
            return []
        return [{"id": r["id"], "role": r["role"], "text": r["text"], "payload": json.loads(r["payload"]), "created": r["created"]}
                for r in self._run("select * from messages where chat_id=? order by created, rowid", chat_id)]

    def history(self, user: str, chat_id: str) -> list[dict[str, str]]:
        """The conversation as the agent is sent it: plain user / assistant turns."""
        msgs = [{"role": m["role"], "content": m["text"]} for m in self.messages(user, chat_id) if m["role"] in ("user", "assistant")]
        return msgs[-HISTORY_TURNS:]
