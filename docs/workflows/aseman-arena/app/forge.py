"""The Game Forge: people describe a game, chat with the Forge agent (the
custom agent the workflow made in the platform's Aseman space), and the agent
builds it — a Godot 4.3 project on the space's computer, tested, exported and
submitted to the Arena with tools/arena_forge.py. The person play-tests it in
their garage and publishes it to the store.

This module writes the agent's brief, talks to it through the developer API
(POST {api}/platform/spaces/ask, as the key's person, in the project's own
thread of the Forge room when the node allows one, else in temporary
threads with the conversation in the brief) and reads its replies.
"""

import json
import urllib.error
import urllib.request

GAME_CONTRACT = """\
Every Arena game is a Godot 4.3 project, single-player against AI opponents (no networking, no other humans):
- Folder: /workspace/forge/{pid}/project — project.godot (config/features "4.3", renderer gl_compatibility,
  rendering/textures/vram_compression/import_etc2_astc=true), export_presets.cfg (a "Web" preset, thread_support=false),
  game.json (the store manifest) and everything else under arena/<slug_underscored>/ (res:// paths there), tests under tests/.
- The main scene's root script declares `signal arena_event(json: String)` and the methods
  `arena_start(params: Dictionary)`, `arena_stop()` and `arena_state() -> Dictionary`.
  It emits JSON events: {"type":"ready"} when loaded, {"type":"started"} when a match starts, and exactly one
  {"type":"result","game":"<slug>","outcome":"win|loss|draw","score":<int ≥ 0>,"duration_s":<int>, …game stats} when it ends.
  When it is the main scene (a Web build) it starts itself from the page's query string.
- It is mounted as a resource pack inside another Godot world: no autoloads, no class_name (use preload), input actions
  added in code with InputMap, no project-setting assumptions; touch controls as well as keyboard/mouse.
- AI opponents: real decision making (search, state machines, utility AI, pathfinding), with difficulty levels in params.
- Models: CC0 only (Poly Haven, Kenney, Quaternius) fetched at build time with
  python3 /workspace/apps/{app}/games/fetch_assets.py style manifests, or procedural meshes; record licences in game.json "credits".
- game.json: slug, title (≤ 40), version, tagline, description, genre, tags, mode "single-player vs AI",
  players {"humans": 1, "ai": <n or text>}, engine "godot-4.3", scene "res://arena/<…>/main.tscn",
  pack "<slug>.pck", web "web/index.html", accent, settings (the params a room can set), scoring, controls, credits.
- Headless tests in tests/run_tests.gd (extends SceneTree, prints "<slug>-tests passed" and quits 0) that start a
  match, drive it and check the result event.
"""

SUBMIT = """\
When the game works, submit it (it validates the manifest and the scene contract, runs the tests headless,
exports the pack and the Web build, and hands the build to the Arena):
  python3 /workspace/apps/{app}/tools/arena_forge.py submit --project {pid} --dir /workspace/forge/{pid}/project
It prints "forge-submitted <slug> <version>" or what to fix. Fix and submit again until it is accepted.
"""


class ForgeError(Exception):
    pass


def brief(project, history, message, app_slug):
    """What the Forge agent is asked for one message of the conversation."""
    pid = project["id"]
    lines = [
        "You are building a game for a person on Aseman Arena, in the Game Forge.",
        "Project %s — \"%s\" (%s). Status: %s." % (pid, project["title"], project.get("genre") or "any genre", project["status"]),
        "The person's brief: " + project["brief"],
        "",
        GAME_CONTRACT.replace("{pid}", pid).replace("{app}", app_slug),
        SUBMIT.replace("{pid}", pid).replace("{app}", app_slug),
        "Work in /workspace/forge/%s. Talk with the person like a senior game designer: ask what matters when the brief is"
        " unclear, propose a design (core loop, the AI opponents and how they decide, controls, look, scoring), then build"
        " it, test it, submit it, and tell them what you made and how to play it. Keep replies short and concrete." % pid,
    ]
    if history:
        lines.append("")
        lines.append("The conversation so far (oldest first):")
        for m in history[-16:]:
            who = "Person" if m["role"] == "user" else "You"
            lines.append("%s: %s" % (who, m["text"][:1500]))
    lines.append("")
    lines.append("The person now says: " + message)
    return "\n".join(lines)


class Client:
    """The developer API's platform door, as the server key's person."""

    def __init__(self, api_url, key, space, bot, room="", timeout=1800):
        self.api_url = (api_url or "").rstrip("/")
        self.key, self.space, self.bot, self.room, self.timeout = key, space, bot, room, timeout

    @property
    def ready(self):
        return bool(self.api_url and self.key and self.space and self.bot)

    def _post(self, path, payload, timeout=None):
        req = urllib.request.Request(self.api_url + path, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raise ForgeError("the Forge agent could not be reached (%s): %s" % (e.code, e.read().decode(errors="replace")[:300]))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ForgeError("the Forge agent could not be reached: %s" % e)

    def open_thread(self, title):
        """A thread of the Forge room for one project, or "" when this node
        or key cannot open one (asks then run in temporary threads)."""
        if not self.room:
            return ""
        try:
            out = self._post("/platform/spaces/thread_create", {"room": self.room, "title": title[:80]}, timeout=30)
        except ForgeError:
            return ""
        t = out.get("thread") if isinstance(out.get("thread"), dict) else out
        return str((t or {}).get("id") or "")

    def ask(self, body, thread=""):
        payload = {"space": self.space, "bot": self.bot, "body": body}
        if thread:
            payload["thread"] = thread
        else:
            payload["temp_thread"] = True
            if self.room:
                payload["room"] = self.room
        out = self._post("/platform/spaces/ask", payload)
        reply = out.get("reply")
        if not reply:
            raise ForgeError("the Forge agent gave no reply")
        return str(reply)
