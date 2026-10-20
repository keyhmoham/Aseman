"""Durable runtime state beside the LangGraph checkpoints.

Open questions are the deep agents human-in-the-loop interrupts the runtime is
waiting on (an agent's ``ask_user``, or a tool that needs approval); each
thread has at most one. The room cursor is how far into its room an agent has
read, so a turn starts by catching up on what was said since. On the OpenCode
engine each thread's conversation is an OpenCode session (``sessions``) and its
plan is kept here (``todos``).
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass
class Question:
    id: str
    vm_id: str
    bot_id: str
    agent: str
    space_id: str
    room_id: str
    thread_id: str
    question: str
    kind: str = "question"  # "question" (ask_user) or "approval"
    options: list[str] = field(default_factory=list)
    # The interrupted tool calls, in order: [{"name", "args"}].
    actions: list[dict[str, Any]] = field(default_factory=list)
    asked_at: float = field(default_factory=time.time)
    no_sandbox: bool = False
    no_memory: bool = False
    request_scope: str = ""
    # The parallel instance the question was asked on (Turn.instance).
    instance: str = ""

    def public(self) -> dict[str, Any]:
        """The vmm.AgentQuestion shape."""
        return {
            "id": self.id, "bot_id": self.bot_id, "agent": self.agent, "space_id": self.space_id,
            "room_id": self.room_id, "question": self.question, "options": self.options,
            "kind": self.kind, "asked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.asked_at)),
            "no_sandbox": self.no_sandbox, "no_memory": self.no_memory, "request_scope": self.request_scope,
        }


class Store:
    def __init__(self, path: str) -> None:
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript("""
                CREATE TABLE IF NOT EXISTS questions (
                    id TEXT PRIMARY KEY, thread_id TEXT UNIQUE, vm_id TEXT, space_id TEXT, data TEXT);
                CREATE TABLE IF NOT EXISTS cursors (thread_id TEXT PRIMARY KEY, seen TEXT);
                CREATE TABLE IF NOT EXISTS generations (thread_id TEXT PRIMARY KEY, gen INTEGER);
                CREATE TABLE IF NOT EXISTS sessions (thread_id TEXT PRIMARY KEY, session_id TEXT);
                CREATE TABLE IF NOT EXISTS todos (thread_id TEXT PRIMARY KEY, data TEXT);
                CREATE TABLE IF NOT EXISTS teams (thread_id TEXT PRIMARY KEY, data TEXT);
            """)
            self._db.commit()

    @staticmethod
    def new_id() -> str:
        return uuid.uuid4().hex

    def put_question(self, q: Question) -> None:
        with self._lock:
            self._db.execute("DELETE FROM questions WHERE thread_id = ?", (q.thread_id,))
            self._db.execute("INSERT INTO questions (id, thread_id, vm_id, space_id, data) VALUES (?, ?, ?, ?, ?)",
                             (q.id, q.thread_id, q.vm_id, q.space_id, json.dumps(asdict(q))))
            self._db.commit()

    def question_for_thread(self, thread_id: str) -> Question | None:
        with self._lock:
            row = self._db.execute("SELECT data FROM questions WHERE thread_id = ?", (thread_id,)).fetchone()
        return Question(**_known(json.loads(row[0]))) if row else None

    def drop_question(self, thread_id: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM questions WHERE thread_id = ?", (thread_id,))
            self._db.commit()

    def questions(self, vm_id: str, space_id: str) -> list[Question]:
        with self._lock:
            rows = self._db.execute("SELECT data FROM questions WHERE vm_id = ? AND (? = '' OR space_id = ?)",
                                    (vm_id, space_id, space_id)).fetchall()
        out = [Question(**_known(json.loads(r[0]))) for r in rows]
        out.sort(key=lambda q: q.asked_at)
        return out

    def generation(self, thread_id: str) -> int:
        """Which conversation of a thread is current: a thread that can no
        longer fit the model's window starts a new one."""
        with self._lock:
            row = self._db.execute("SELECT gen FROM generations WHERE thread_id = ?", (thread_id,)).fetchone()
        return int(row[0]) if row else 0

    def next_generation(self, thread_id: str) -> int:
        with self._lock:
            self._db.execute("INSERT INTO generations (thread_id, gen) VALUES (?, 1) "
                             "ON CONFLICT(thread_id) DO UPDATE SET gen = gen + 1", (thread_id,))
            self._db.commit()
            row = self._db.execute("SELECT gen FROM generations WHERE thread_id = ?", (thread_id,)).fetchone()
        return int(row[0])

    def seen(self, thread_id: str) -> str:
        with self._lock:
            row = self._db.execute("SELECT seen FROM cursors WHERE thread_id = ?", (thread_id,)).fetchone()
        return row[0] if row else ""

    def mark_seen(self, thread_id: str, created_at: str) -> None:
        if not created_at:
            return
        with self._lock:
            self._db.execute("INSERT INTO cursors (thread_id, seen) VALUES (?, ?) "
                             "ON CONFLICT(thread_id) DO UPDATE SET seen = excluded.seen", (thread_id, created_at))
            self._db.commit()

    # --- the OpenCode engine --------------------------------------------------

    def session(self, thread_id: str) -> str:
        """The OpenCode session of a thread's conversation ('' when it has none yet)."""
        with self._lock:
            row = self._db.execute("SELECT session_id FROM sessions WHERE thread_id = ?", (thread_id,)).fetchone()
        return row[0] if row else ""

    def put_session(self, thread_id: str, session_id: str) -> None:
        with self._lock:
            self._db.execute("INSERT INTO sessions (thread_id, session_id) VALUES (?, ?) "
                             "ON CONFLICT(thread_id) DO UPDATE SET session_id = excluded.session_id",
                             (thread_id, session_id))
            self._db.commit()

    def todos(self, thread_id: str) -> list[dict[str, Any]]:
        with self._lock:
            row = self._db.execute("SELECT data FROM todos WHERE thread_id = ?", (thread_id,)).fetchone()
        return list(json.loads(row[0])) if row else []

    def put_todos(self, thread_id: str, todos: list[dict[str, Any]]) -> None:
        with self._lock:
            self._db.execute("INSERT INTO todos (thread_id, data) VALUES (?, ?) "
                             "ON CONFLICT(thread_id) DO UPDATE SET data = excluded.data",
                             (thread_id, json.dumps(todos)))
            self._db.commit()

    # --- the swarm --------------------------------------------------------------

    def team(self, thread_id: str) -> dict[str, Any] | None:
        """The team the lead last set up on a thread (swarm.team_setup.Team.json)."""
        with self._lock:
            row = self._db.execute("SELECT data FROM teams WHERE thread_id = ?", (thread_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def put_team(self, thread_id: str, team: dict[str, Any]) -> None:
        with self._lock:
            self._db.execute("INSERT INTO teams (thread_id, data) VALUES (?, ?) "
                             "ON CONFLICT(thread_id) DO UPDATE SET data = excluded.data", (thread_id, json.dumps(team)))
            self._db.commit()


_FIELDS = frozenset(Question.__dataclass_fields__)


def _known(data: dict[str, Any]) -> dict[str, Any]:
    """A stored question's fields this version knows (older rows lack newer ones)."""
    return {k: v for k, v in data.items() if k in _FIELDS}
