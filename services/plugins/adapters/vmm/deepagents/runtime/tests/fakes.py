"""A fake aseman node (the agent gateway's action API) and a scripted model."""

from __future__ import annotations

import base64
import itertools
import json
import re
import os
import subprocess
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

import httpx
from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from pydantic import Field

from aseman_agents.gateway import Gateway

SPACE = "space-1"
ROOM = "room-1"
LEAD = {"id": "bot-lead", "account_id": "acc-lead", "name": "aseman", "vm_id": "deepagents-aseman"}
CODER = {"id": "bot-coder", "account_id": "acc-coder", "name": "coder", "vm_id": "vm-coder"}
PERSON = {"member_id": "acc-ann", "handle": "ann"}
SANDBOX_BOT = "bot-sandbox"


def _default_codemode(message: dict[str, Any]) -> dict[str, Any]:
    """Minimal Code Mode MCP: tools/list with search + execute."""
    mid = message.get("id", 1)
    method = message.get("method")
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "search", "description": "Search OpenAPI", "inputSchema": {
                "type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}},
            {"name": "execute", "description": "Execute against apps", "inputSchema": {
                "type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}},
        ]}}
    if method == "tools/call":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": json.dumps({"ok": True})}], "isError": False}}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "aseman-codemode", "version": "1.0.0"}}}
    return {"jsonrpc": "2.0", "id": mid, "result": {}}


class Platform:
    """Answers /call like the node would, for one space."""

    def __init__(self, workdir: str) -> None:
        self.workdir = workdir
        self.messages: list[dict[str, Any]] = []
        self.logs: list[dict[str, Any]] = []
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.dms: list[dict[str, Any]] = []
        self.tool_runs: list[dict[str, Any]] = []
        self.bots = [dict(LEAD, kind="agent", vm_type="deepagents", description="Leads the space."),
                     dict(CODER, kind="agent", vm_type="deepagents", description="Writes and tests code."),
                     {"id": SANDBOX_BOT, "account_id": "acc-sandbox", "name": "sandbox", "kind": "tool",
                      "vm_type": "docker", "vm_id": "sbx"}]
        self.tokens: dict[str, str] = {}  # token → account
        # Whether the provider serves a sleeping computer's files (Modal does, Docker does not).
        self.stored_files = True
        # A new project has no computer until something is run on it.
        self.has_computer = True
        # Connected apps (remote MCP servers) of the space, as spaces.tools_list returns them.
        self.apps: list[dict[str, Any]] = []
        # What a connected app answers a call with.
        self.app_reply = '{"content": [{"type": "text", "text": "ok"}]}'
        # Agents that answer a task the moment it is posted: account → fn(body) → reply.
        self.responders: dict[str, Callable[[str], str]] = {}
        # Agents that answer after working a while: account → (seconds, fn(body) → reply).
        self.workers: dict[str, tuple[float, Callable[[str], str]]] = {}
        self.working = 0
        self.most_working = 0
        # The node's decision model: fn(state, questions) → answers; None is off (409).
        self.decide: Callable[[Any, dict[str, Any]], dict[str, Any]] | None = None
        self.decisions: list[dict[str, Any]] = []
        self.decision_status = 200
        # The space's timeline MCP server: fn(message) → JSON-RPC reply; None is off (503).
        self.timeline: Callable[[dict[str, Any]], dict[str, Any]] | None = None
        self.timeline_calls: list[dict[str, Any]] = []
        # Cloudflare Code Mode MCP over space apps: fn(message) → JSON-RPC reply; None is off.
        self.codemode: Callable[[dict[str, Any]], dict[str, Any]] | None = _default_codemode
        self.codemode_calls: list[dict[str, Any]] = []
        # The node's learn endpoints (self-improvement): each model call answers
        # with the next step of this script (say, use), recorded in learn_requests.
        self.learn: list[Any] = []
        self.learn_requests: list[dict[str, Any]] = []
        # The marketplace's active agent listings, as market.catalog returns them.
        self.catalog: list[dict[str, Any]] = []
        self.hired: list[str] = []
        self._ids = itertools.count(1)
        self._clock = datetime(2026, 1, 1, tzinfo=timezone.utc)

    def gateway(self, base: str, token: str) -> Gateway:
        return Gateway(base, token, transport=httpx.MockTransport(self.ahandle),
                       sync_transport=httpx.MockTransport(self.handle))

    async def ahandle(self, request: httpx.Request) -> httpx.Response:
        """The gateway as a turn's async client sees it: a hand-off that waits
        (``message_send`` with ``wait``) returns once the mentioned agents answered."""
        if request.url.path.endswith("/call"):
            req = json.loads(request.content)
            body = req.get("body") or {}
            caller = self.tokens.get(request.headers.get("Authorization", "").removeprefix("Bearer "), "")
            if caller and req.get("action") == "message_send" and body.get("wait"):
                self.calls.append(("spaces.message_send", body))
                return httpx.Response(200, json=await self.send_and_wait(caller, body))
        return self.handle(request)

    def now(self) -> str:
        self._clock += timedelta(seconds=1)
        return self._clock.isoformat().replace("+00:00", "Z")

    def post(self, sender: str, body: str, *, kind: str = "", reply_to: str = "", mentions: list[str] | None = None) -> str:
        mid = f"m{next(self._ids)}"
        self.messages.append({"id": mid, "space_id": SPACE, "room_id": ROOM, "sender_id": sender, "body": body,
                              "kind": kind, "reply_to": reply_to, "mentions": mentions or [], "created_at": self.now(),
                              "sender": {"id": sender, "display_name": sender}, "attachments": []})
        return mid

    # --- the gateway --------------------------------------------------------

    def handle(self, request: httpx.Request) -> httpx.Response:
        if "/learn/" in request.url.path:
            # The agents' learning (GEPA): the runtime's own credential, no turn.
            if request.headers.get("X-Aseman-Runtime") != "test-secret":
                return httpx.Response(401, json={"error": {"message": "bad runtime secret"}})
            req = json.loads(request.content)
            self.learn_requests.append({**req, "space": request.headers.get("X-Aseman-Space"),
                                        "agent": request.headers.get("X-Aseman-Agent")})
            if request.url.path.endswith("/decision/evaluate"):
                return self.handle_decision(req)
            return self.handle_learn(req)
        caller = self.tokens.get(request.headers.get("Authorization", "").removeprefix("Bearer "), "")
        if not caller:
            return httpx.Response(401, json={"error": "bad token"})
        req = json.loads(request.content)
        if request.url.path.endswith("/decision/evaluate"):
            return self.handle_decision(req)
        if request.url.path.endswith("/timeline/mcp"):
            self.timeline_calls.append(req)
            if self.timeline is None:
                return httpx.Response(503, json={"error": "the timeline is not available"})
            return httpx.Response(200, json=self.timeline(req))
        if request.url.path.endswith("/codemode/mcp"):
            self.codemode_calls.append(req)
            if self.codemode is None:
                return httpx.Response(503, json={"error": "Code Mode is not available"})
            return httpx.Response(200, json=self.codemode(req))
        name = f"{req['namespace']}.{req['action']}"
        body = req.get("body") or {}
        self.calls.append((name, body))
        fn = getattr(self, "do_" + name.replace(".", "_"), None)
        if fn is None:
            return httpx.Response(403, json={"error": f"{name} not allowed"})
        try:
            return httpx.Response(200, json=fn(caller, body))
        except KeyError as exc:
            return httpx.Response(400, json={"error": f"missing {exc}"})

    def handle_decision(self, req: dict[str, Any]) -> httpx.Response:
        self.decisions.append(req)
        if self.decide is None:
            return httpx.Response(409, json={"error": {"code": "decision_disabled"}})
        if self.decision_status != 200:
            return httpx.Response(self.decision_status, json={"error": {"message": "decision provider down"}})
        answers = self.decide(req["state"], req["questions"])
        return httpx.Response(200, json={"model": "typesafe-ai/jev", "answers": answers,
                                         "usage": {"inputTokens": 50 * len(req["questions"]), "outputTokens": 0}})

    def handle_learn(self, req: dict[str, Any]) -> httpx.Response:
        step = self.learn.pop(0) if self.learn else say("(script exhausted)")
        if callable(step):
            step = step(req)
        message: dict[str, Any] = {"role": "assistant", "content": step.get("content", "")}
        calls = [{"id": f"call_{next(self._ids)}", "type": "function",
                  "function": {"name": name, "arguments": json.dumps(args)}} for name, args in step.get("tool_calls", [])]
        if calls:
            message["tool_calls"] = calls
        usage = {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110}
        return httpx.Response(200, json={"id": "c1", "object": "chat.completion", "created": 1, "model": "m",
                                         "choices": [{"index": 0, "message": message,
                                                      "finish_reason": "tool_calls" if calls else "stop"}],
                                         "usage": usage})

    def do_market_catalog(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        return {"items": self.catalog}

    def do_spaces_agent_hire(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        row = next(r for r in self.catalog if r["listing"]["id"] == body["listing"])
        bot = row["bot"]
        self.hired.append(body["listing"])
        if not any(b["id"] == bot["id"] for b in self.bots):
            self.bots.append(dict(bot, kind="agent", vm_type="deepagents", description=row.get("description", "")))
        return {"bot_id": bot["id"], "account_id": bot["account_id"], "name": bot["name"],
                "description": row.get("description", "")}

    def do_spaces_tools_list(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        return {"tools": [
            {"name": "sandbox_exec", "kind": "tool", "description": "shell", **({"bot_id": SANDBOX_BOT} if self.has_computer else {})},
            {"name": "file_send", "kind": "tool", "description": "Attach a sandbox file.",
             "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "caption": {"type": "string"}}}},
            {"name": "weather", "kind": "tool", "bot_id": "bot-weather", "description": "Weather forecasts."},
            {"name": "appui_create", "kind": "tool", "description": "Brief OpenCode to build an interactive UI on the desk.",
             "parameters": {"type": "object", "properties": {"title": {"type": "string"}, "brief": {"type": "string"},
                                                              "tool": {"type": "string"}}, "required": ["brief"]}},
            *self.apps,
        ]}

    def do_spaces_bots_list(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        return {"bots": [dict(b, member_id=b["account_id"]) for b in self.bots]}

    def do_spaces_members_list(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        return {"members": [dict(PERSON, role="owner", kind="user")]}

    def do_spaces_ask(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        if body.get("tool"):
            self.tool_runs.append({"tool": body["tool"], "args": body.get("args"), "by": caller})
            return {"tool": body["tool"], "result": "done"}
        if body["bot"] in (SANDBOX_BOT, "sandbox"):
            proc = subprocess.run(["sh", "-c", body["body"]], cwd=self.workdir, capture_output=True, text=True, timeout=60)
            out = proc.stdout + proc.stderr
            return {"bot_id": SANDBOX_BOT, "reply": f"exit={proc.returncode}\n{out}", "exit_code": proc.returncode, "output": out}
        self.tool_runs.append({"bot": body["bot"], "body": body["body"], "by": caller})
        if any(app.get("bot_id") == body["bot"] for app in self.apps):
            return {"bot_id": body["bot"], "reply": self.app_reply}
        return {"bot_id": body["bot"], "reply": "sunny"}

    def do_spaces_sandbox_files(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        """The project's stored files: served without the computer."""
        if not self.has_computer:
            return {"items": []} if body["operation"] == "list" else {"ok": False, "missing": True}
        if not self.stored_files:
            return {"ok": False, "asleep": True}
        root = Path(os.environ["ASEMAN_WORKSPACE"])
        target = root / body.get("path", ".")
        op = body["operation"]
        if op == "list":
            if not target.is_dir():
                return {"ok": False, "missing": True}
            return {"items": [{"name": p.name, "type": "dir" if p.is_dir() else "file",
                               "size": 0 if p.is_dir() else p.stat().st_size} for p in sorted(target.iterdir())]}
        if op == "read":
            if not target.is_file():
                return {"ok": False, "missing": True}
            data = target.read_bytes()
            return {"content": data.decode(errors="replace"), "data_base64": base64.b64encode(data).decode(), "size": len(data)}
        if op == "write":
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(base64.b64decode(body["data_base64"]) if body.get("data_base64") else body.get("content", "").encode())
            return {"ok": True}
        if op == "delete":
            import shutil

            shutil.rmtree(target) if target.is_dir() else target.unlink(missing_ok=True)
            return {"ok": True}
        return {"ok": False, "error": "unsupported"}

    def do_spaces_message_send(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        mid = self.post(caller, body["body"], reply_to=body.get("reply_to", ""), mentions=body.get("mentions"))
        for account in body.get("mentions") or []:
            if account in self.responders:
                self.post(account, self.responders[account](body["body"]), reply_to=mid)
            if account in self.workers:
                import asyncio

                delay, fn = self.workers[account]
                self.working += 1
                self.most_working = max(self.most_working, self.working)

                def done(account: str = account, text: str = body["body"], fn: Any = fn) -> None:
                    self.working -= 1
                    self.post(account, fn(text), reply_to=mid)

                asyncio.get_running_loop().call_later(delay, done)
        return {"message_id": mid, "ok": True}

    async def send_and_wait(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        import asyncio

        mid = self.post(caller, body["body"], reply_to=body.get("reply_to", ""), mentions=body.get("mentions"))

        async def run(account: str) -> dict[str, Any] | None:
            bot = next((b for b in self.bots if b["account_id"] == account), {"id": account, "name": account})
            if account in self.responders:
                text = self.responders[account](body["body"])
            elif account in self.workers:
                delay, fn = self.workers[account]
                self.working += 1
                self.most_working = max(self.most_working, self.working)
                await asyncio.sleep(delay)
                self.working -= 1
                text = fn(body["body"])
            else:
                return None
            reply_id = self.post(account, text, reply_to=mid)
            return {"bot_id": bot["id"], "bot_handle": bot["name"], "message_id": reply_id, "reply": text}

        replies = await asyncio.gather(*(run(a) for a in body.get("mentions") or []))
        return {"message_id": mid, "ok": True, "replies": [r for r in replies if r]}

    def do_spaces_message_list(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        msgs = [m for m in self.messages if not body.get("reply_to") or m["reply_to"] == body["reply_to"]]
        if body.get("after"):
            msgs = [m for m in msgs if m["created_at"] > body["after"]]
            return {"messages": msgs[: body.get("limit", 50)]}
        return {"messages": list(reversed(msgs))[: body.get("limit", 50)]}

    def do_spaces_agent_log(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        self.logs.append({"by": caller, **body})
        if body.get("text"):
            self.post(caller, body["text"], kind="log")
        return {"ok": True}

    def do_spaces_agent_recruit(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        n = next(self._ids)
        bot = {"id": f"bot-r{n}", "account_id": f"acc-r{n}", "name": f"{body['name']}-{n:04x}", "vm_id": f"vm-r{n}",
               "kind": "agent", "vm_type": "deepagents", "description": body.get("description", "")}
        self.bots.append(bot)
        return {"bot_id": bot["id"], "account_id": bot["account_id"], "name": bot["name"]}

    def do_users_dm_send(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        self.dms.append({"from_id": caller, "to_id": body["to"], "body": body["body"], "created_at": self.now()})
        return {"id": f"d{len(self.dms)}", "ok": True}

    def do_users_dm_list(self, caller: str, body: dict[str, Any]) -> dict[str, Any]:
        peer = body["peer"]
        return {"messages": [d for d in self.dms if {d["from_id"], d["to_id"]} == {caller, peer}]}


class ScriptedModel(BaseChatModel):
    """Answers each model call with the next step of a script. A step is an
    AIMessage, or a function of the conversation that returns one."""

    script: list[Any]
    # Per-instance via default_factory (avoid shared mutable class defaults).
    seen: list[list[BaseMessage]] = Field(default_factory=list)
    offered: list[list[str]] = Field(default_factory=list)

    @property
    def _llm_type(self) -> str:
        return "scripted"

    def bind_tools(self, tools: Any, **kwargs: Any) -> "ScriptedModel":
        names: list[str] = []
        for t in tools or []:
            if isinstance(t, dict):
                names.append(str(t.get("name") or (t.get("function") or {}).get("name") or ""))
            else:
                names.append(str(getattr(t, "name", "") or ""))
        self.offered.append(names)
        return self

    def _generate(self, messages: list[BaseMessage], stop: Any = None, run_manager: Any = None, **kwargs: Any) -> ChatResult:
        self.seen.append(list(messages))
        if not self.script:
            step: Any = AIMessage(content="(script exhausted)")
        else:
            step = self.script.pop(0)
        if callable(step):
            step = step(messages)
        return ChatResult(generations=[ChatGeneration(message=step)])


def say(text: str) -> dict[str, Any]:
    """A learn step (Platform.learn): the model answers with text."""
    return {"content": text}


def use(name: str, args: dict[str, Any] | None = None, *more: tuple[str, dict[str, Any]], text: str = "") -> dict[str, Any]:
    """A learn step: the model calls tools (several at once with ``more``)."""
    return {"content": text, "tool_calls": [(name, args or {}), *more]}


def listing(n: int, name: str, description: str, usecases: list[str] | None = None) -> dict[str, Any]:
    """A marketplace catalog row (market.catalog) for an agent."""
    bot = {"id": f"bot-m{n}", "account_id": f"acc-m{n}", "name": name, "kind": "agent", "vm_type": "deepagents"}
    return {"bot": bot, "kind": "agent", "status": "active", "description": description,
            "descriptor": {"name": name, "description": description, "usecases": usecases or []},
            "listing": {"id": f"lst-{n}", "bot_id": bot["id"], "name": name, "status": "active", "installs": 3}}


def call(name: str, args: dict[str, Any], cid: str | None = None) -> AIMessage:
    return AIMessage(content="", tool_calls=[{"name": name, "args": args, "id": cid or f"call-{name}", "type": "tool_call"}])


def turn_request(agent: dict[str, Any], message: str, *, token: str, sender: str = "acc-ann", sender_name: str = "ann",
                 message_id: str = "", role: str = "", **extra: Any) -> dict[str, Any]:
    # Match production (turn.go): Code Mode is on unless a test opts out.
    agent_extra = {k: v for k, v in extra.items() if k not in ("codemode", "timeline", "memory", "decision")}
    req: dict[str, Any] = {
        "token": token, "gateway": "http://node/deepagents/v1",
        "codemode": extra.get("codemode", True),
        "agent": {"name": agent["name"], "bot_id": agent["id"], "account_id": agent["account_id"],
                  "vm_id": agent["vm_id"], "role": role, "model": "test-model", **agent_extra},
        "turn": {"agent": {"bot_id": agent["id"], "account_id": agent["account_id"], "name": agent["name"]},
                 "space_id": SPACE, "room_id": ROOM, "message_id": message_id, "sender_id": sender,
                 "sender_name": sender_name, "message": message, "context": "Space: test",
                 "sandbox": {"type": "docker", "vm_id": "sbx"}},
    }
    if "timeline" in extra:
        req["timeline"] = extra["timeline"]
    if "memory" in extra:
        req["memory"] = extra["memory"]
    if "decision" in extra:
        req["decision"] = extra["decision"]
    return req


class FakeViking:
    """Answers OpenViking's HTTP API like a server in trusted mode would, keeping
    each account's files apart."""

    def __init__(self) -> None:
        self.files: dict[tuple[str, str], str] = {}  # (account, uri) → text
        self.sessions: dict[tuple[str, str, str], list[dict[str, Any]]] = {}  # (account, user, id) → messages
        self.commits: list[tuple[str, str, str]] = []
        self.requests: list[tuple[str, str, str, dict[str, Any]]] = []  # (account, user, path, body)
        self.actors: list[tuple[str, str]] = []  # (path, actor peer) of the requests made as a peer
        self.policies: dict[tuple[str, str, str], dict[str, Any]] = {}  # session → auto-commit policy
        self.archived = ""  # the summary of a session's archived history
        self.summaries: dict[str, str] = {}  # uri → its overview
        self.recalled = ""  # what context search renders
        self.down = False
        self.no_auto_commit = False  # a server without session config

    def settings(self) -> Any:
        from aseman_agents.memory import Settings

        return Settings(url="http://openviking:1933", api_key="root-key", transport=httpx.MockTransport(self.handle))

    def _ok(self, result: Any) -> httpx.Response:
        return httpx.Response(200, json={"status": "ok", "result": result})

    def handle(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            return httpx.Response(503, json={"detail": "unavailable"})
        if request.headers.get("X-API-Key") != "root-key":
            return httpx.Response(401, json={"status": "error", "error": {"code": "UNAUTHENTICATED", "message": "no"}})
        account = request.headers.get("X-OpenViking-Account", "")
        user = request.headers.get("X-OpenViking-User", "")
        path = request.url.path
        body = json.loads(request.content) if request.content else dict(request.url.params)
        self.requests.append((account, user, path, body))
        if request.headers.get("X-OpenViking-Actor-Peer"):
            self.actors.append((path, request.headers["X-OpenViking-Actor-Peer"]))
        if path == "/api/v1/content/read":
            text = self.files.get((account, body["uri"]))
            if text is None:
                return httpx.Response(404, json={"status": "error", "error": {
                    "code": "NOT_FOUND", "message": "not found", "details": {"resource": body["uri"]}}})
            return self._ok(text)
        if path in ("/api/v1/content/abstract", "/api/v1/content/overview"):
            return self._ok(self.summaries.get(body["uri"], ""))
        if path == "/api/v1/content/write":
            key = (account, body["uri"])
            if body["mode"] == "create" and key in self.files:
                return httpx.Response(409, json={"status": "error", "error": {
                    "code": "ALREADY_EXISTS", "message": "exists", "details": {"resource": body["uri"]}}})
            text = (self.files.get(key, "") + body["content"]) if body["mode"] == "append" else body["content"]
            # Like OpenViking, a memory file is kept without its last newline.
            self.files[key] = text.rstrip("\n") if "/memories/" in body["uri"] else text
            return self._ok({"uri": body["uri"]})
        if path == "/api/v1/search/search" and body.get("mode") == "context":
            return self._ok({"entries": [], "rendered": self.recalled})
        if path == "/api/v1/search/find":
            words = body["query"].lower().split()
            hits = [{"uri": uri, "abstract": text[:200], "score": 0.9} for (acc, uri), text in self.files.items()
                    if acc == account and any(w in text.lower() for w in words)]
            return self._ok({"memories": hits, "resources": [], "skills": []})
        if path == "/api/v1/search/grep":
            pattern = re.compile(body["pattern"], re.I if body.get("case_insensitive") else 0)
            matches = [{"uri": uri, "line": n + 1, "content": line}
                       for (acc, uri), text in self.files.items() if acc == account and uri.startswith(body["uri"])
                       for n, line in enumerate(text.splitlines()) if pattern.search(line)]
            return self._ok({"matches": matches, "count": len(matches)})
        if path.endswith("/messages/batch"):
            sid = path.split("/")[-3]
            self.sessions.setdefault((account, user, sid), []).extend(body["messages"])
            return self._ok({"added": len(body["messages"])})
        if path.endswith("/config") and request.method == "PATCH" and not self.no_auto_commit:
            self.policies[(account, user, path.split("/")[-2])] = body["auto_commit_policy"]
            return self._ok({})
        if path.endswith("/context") and request.method == "GET":
            sid = path.split("/")[-2]
            messages = self.sessions.get((account, user, sid))
            if messages is None:
                return httpx.Response(404, json={"status": "error", "error": {"code": "NOT_FOUND", "message": "no"}})
            return self._ok({"latest_archive_overview": self.archived, "messages": messages})
        if path.endswith("/commit"):
            self.commits.append((account, user, path.split("/")[-2]))
            return self._ok({"task_id": "t1", "status": "accepted"})
        return httpx.Response(404, json={"detail": f"no route {path}"})
