"""The ``aseman`` MCP server DeepSeek Harness mounts on every turn (stdio).

It wires the harness to the platform, on the turn gateway. Memory and the
swarm are the harness's own (the aseman-memory plugin; subagents, Agent
Teams and workflows), so they are not here:

* space tools — the same messaging, team, space-tool, recruit/hire and
  personal-account tools the OpenCode bridge serves (shared module);
* timeline and Code Mode — the gateway's MCP servers, forwarded;
* questions — ask_user pauses the thread until a person answers;
* dispatch — delegate_task hands another Aseman agent a task (its own turn
  answers);
* creator mode — create_app / create_plugin / app_status / publish_app are
  Aseman's on-demand app generation (appui_*), the platform's plugins;
* platform_call — the escape hatch (never an LLM call, never the runtime).
"""

from __future__ import annotations

import itertools
import json
import os
import sys
from pathlib import Path
from typing import Any

from aseman_agents.gateway import Gateway, GatewayError
from aseman_agents.opencode_engine import space_tools

from .cli import pause_path
from .mapping import reject

SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2025-03-26"
RESULT_MAX_CHARS = 20000
TASK_TIMEOUT = 45 * 60.0

_ids = itertools.count(1)
_obj = {"type": "object"}


def env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def room_mode() -> bool:
    return space_tools.mode() == "room"


# --- tool catalog ------------------------------------------------------------


def _engine_tools() -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = [
        {"name": "ask_user", "description": (
            "Ask the people in the conversation a question and stop: the run ends and continues "
            "with their answer. Use it when you need a decision, a confirmation or missing facts."
        ), "inputSchema": {**_obj, "properties": {
            "question": {"type": "string"},
            "options": {"type": "array", "items": {"type": "string"}},
        }, "required": ["question"]}},
    ]
    if room_mode():
        tools += [
            {"name": "delegate_task", "description": (
                "Hand a task to a teammate agent of this space (by name, @handle, bot or account id). "
                "Its own turn runs on the task in the room and its answer comes back here. "
                "Brief it completely: it does not see your conversation."
            ), "inputSchema": {**_obj, "properties": {
                "agent": {"type": "string"}, "task": {"type": "string"},
            }, "required": ["agent", "task"]}},
            {"name": "create_app", "description": (
                "Creator mode: build an on-demand app for the space with Aseman's app generation "
                "(appui_create). Write a complete brief: what it is for, its screens and data, the "
                "space apps/agents it uses, and what someone should see at a glance on its phone widget."
            ), "inputSchema": {**_obj, "properties": {
                "brief": {"type": "string"}, "title": {"type": "string"},
                "ui": {"type": "string", "description": "elpian (default) or web"},
                "apps": {"type": "array", "items": {"type": "string"}},
                "agents": {"type": "array", "items": {"type": "string"}},
                "tool": {"type": "string", "description": "dock association: a tool bot id"},
                "dir": {"type": "string", "description": "an existing app's dir, to change it"},
            }, "required": ["brief"]}},
            {"name": "create_plugin", "description": (
                "Creator mode: create a plugin for this space — a lasting tool with a backend people and "
                "agents can call — through Aseman's app generation. Describe its operations, data and UI."
            ), "inputSchema": {**_obj, "properties": {
                "name": {"type": "string"}, "purpose": {"type": "string"},
                "operations": {"type": "array", "items": {"type": "string"}},
                "ui": {"type": "string"},
            }, "required": ["name", "purpose"]}},
            {"name": "app_status", "description": "Status of an app being generated (its dir).",
             "inputSchema": {**_obj, "properties": {"dir": {"type": "string"}}, "required": ["dir"]}},
            {"name": "publish_app", "description": (
                "Verify a built app and open it on the desk (appui_publish). Not ready, it says what to fix."
            ), "inputSchema": {**_obj, "properties": {"dir": {"type": "string"}}, "required": ["dir"]}},
        ]
    tools.append({"name": "platform_call", "description": (
        "Escape hatch: call one Aseman platform action by namespace/action when no named tool fits. "
        "Never an LLM call and never a change to this runtime."
    ), "inputSchema": {**_obj, "properties": {
        "namespace": {"type": "string"}, "action": {"type": "string"}, "body": _obj,
    }, "required": ["namespace", "action"]}})
    return tools


class Bridge:
    """The tools of one turn; gateway MCP servers are listed once."""

    def __init__(self, gateway: Gateway) -> None:
        self.gateway = gateway
        self._forwarded: dict[str, tuple[str, str]] | None = None
        self._forwarded_defs: list[dict[str, Any]] = []

    def tools(self) -> list[dict[str, Any]]:
        self._forward_list()
        return space_tools.space_tool_defs() + self._forwarded_defs + _engine_tools()

    # Timeline and Code Mode: the gateway's own MCP servers, renamed so the
    # model sees the same tool names a Deep Agents turn does.
    def _forward_list(self) -> None:
        if self._forwarded is not None:
            return
        self._forwarded = {}
        if not room_mode():
            return
        servers = []
        if env("ASEMAN_ENGINE_CODEMODE") == "1":
            servers.append(("codemode", {"search": "codemode_search", "execute": "codemode_execute"}))
        if env("ASEMAN_ENGINE_TIMELINE") == "1":
            from aseman_agents.timeline import TOOL_NAMES
            servers.append(("timeline", TOOL_NAMES))
        for server, names in servers:
            try:
                listed = self._rpc(server, "tools/list", {}).get("tools") or []
            except Exception:  # noqa: BLE001 - the turn works without it
                continue
            for spec in listed:
                raw = str(spec.get("name") or "")
                if raw not in names:
                    continue
                self._forwarded[names[raw]] = (server, raw)
                self._forwarded_defs.append({
                    "name": names[raw], "description": str(spec.get("description") or raw),
                    "inputSchema": spec.get("inputSchema") or dict(_obj),
                })

    def _rpc(self, server: str, method: str, params: dict[str, Any]) -> dict[str, Any]:
        message = {"jsonrpc": "2.0", "id": next(_ids), "method": method, "params": params}
        resp = self.gateway._sync.post(f"{self.gateway.base_url}/{server}/mcp", json=message, timeout=300.0)
        if resp.status_code >= 400:
            raise GatewayError(f"{server} {method}: HTTP {resp.status_code} {resp.text[:300]}")
        reply = resp.json()
        if reply.get("error"):
            err = reply["error"]
            raise GatewayError(f"{server} {method}: {err.get('message') if isinstance(err, dict) else err}")
        return reply.get("result") or {}

    def call(self, name: str, args: dict[str, Any]) -> tuple[str, bool]:
        args = args if isinstance(args, dict) else {}
        try:
            if name in {t["name"] for t in space_tools.space_tool_defs()}:
                return space_tools.call_space_tool(self.gateway, name, args)
            self._forward_list()
            if self._forwarded and name in self._forwarded:
                server, raw = self._forwarded[name]
                result = self._rpc(server, "tools/call", {"name": raw, "arguments": args})
                return _content_text(result), bool(result.get("isError"))
            handler = {
                "ask_user": lambda: (_ask(args), False),
                "delegate_task": lambda: (self._delegate(args), False),
                "create_app": lambda: (self._appui("appui_create", _app_args(args)), False),
                "create_plugin": lambda: (self._appui("appui_create", _plugin_args(args)), False),
                "app_status": lambda: (self._appui("appui_status", {"dir": str(args.get("dir") or "")}), False),
                "publish_app": lambda: (self._appui("appui_publish", {"dir": str(args.get("dir") or "")}), False),
                "platform_call": lambda: self._platform(args),
            }.get(name)
            if handler is not None:
                return handler()
        except GatewayError as exc:
            return str(exc), True
        except Exception as exc:  # noqa: BLE001 - the tool result is the error
            return f"{type(exc).__name__}: {exc}", True
        return f"unknown tool {name}", True

    # --- platform ------------------------------------------------------------

    def _platform(self, args: dict[str, Any]) -> tuple[str, bool]:
        namespace = str(args.get("namespace") or "").strip()
        action = str(args.get("action") or "").strip()
        body = args.get("body") if isinstance(args.get("body"), dict) else {}
        if not namespace or not action:
            return "platform_call needs namespace and action", True
        reason = reject(namespace, action, body)
        if reason:
            return reason, True
        return _clip(self.gateway.call_sync(namespace, action, body)), False

    def _appui(self, tool: str, args: dict[str, Any]) -> str:
        space, room = space_tools.space(), space_tools.room()
        if not space:
            raise GatewayError(f"{tool} needs a space")
        payload: dict[str, Any] = {"space": space, "tool": tool, "args": args}
        if room:
            payload["room"] = room
        # A build (OpenCode or the agents) and the platform's checks take minutes.
        from aseman_agents.gateway import CODEMODE_TIMEOUT, _decode, _payload
        resp = self.gateway._sync.post(self.gateway.base_url + "/call", json=_payload("spaces", "ask", payload),
                                       timeout=CODEMODE_TIMEOUT)
        return _clip(_decode("spaces", "ask", resp))

    def _delegate(self, args: dict[str, Any]) -> str:
        who = str(args.get("agent") or "").strip()
        task = str(args.get("task") or "").strip()
        if not who or not task:
            raise GatewayError("delegate_task needs agent and task")
        member = _find_agent(self.gateway, who)
        if member is None:
            raise GatewayError(f"no agent {who!r} in this space: see list_team, or recruit_agent")
        from aseman_agents.team import new_tag
        payload = {
            "space": space_tools.space(), "room": space_tools.room(),
            "body": f"@{member['name']} [task {new_tag()}] {task}",
            "mentions": [member["account_id"]], "wait": True,
        }
        import httpx
        try:
            resp = self.gateway._sync.post(self.gateway.base_url + "/call", json={
                "namespace": "spaces", "action": "message_send", "body": payload,
            }, timeout=httpx.Timeout(connect=10.0, read=TASK_TIMEOUT, write=60.0, pool=30.0))
        except httpx.TimeoutException:
            return f"(no answer after {int(TASK_TIMEOUT)}s: the task is still open)"
        from aseman_agents.gateway import _decode
        out = _decode("spaces", "message_send", resp)
        reply = next((r for r in out.get("replies") or [] if r.get("bot_id") == member["bot_id"]), None)
        if reply is None:
            raise GatewayError(out.get("error") or f"{member['name']} did not take the task")
        return f"{member['name']}: " + (str(reply.get("reply") or "").strip() or "(answered with no text)")

# --- dispatch helpers ----------------------------------------------------------


def _find_agent(gateway: Gateway, who: str) -> dict[str, str] | None:
    out = gateway.call_sync("spaces", "bots_list", {"space": space_tools.space()})
    key = who.strip().lstrip("@").lower()
    for b in out.get("bots") or []:
        if b.get("kind") != "agent":
            continue
        if key in (str(b.get("name", "")).lower(), str(b.get("id", "")).lower(),
                   str(b.get("account_id", "")).lower()):
            return {"name": str(b.get("name", "")), "account_id": str(b.get("account_id", "")),
                    "bot_id": str(b.get("id", ""))}
    return None


def _app_args(args: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"brief": str(args.get("brief") or "").strip()}
    if not out["brief"]:
        raise GatewayError("create_app needs a brief")
    for key in ("title", "ui", "tool", "dir"):
        if str(args.get(key) or "").strip():
            out[key] = str(args[key]).strip()
    for key in ("apps", "agents"):
        if isinstance(args.get(key), list) and args[key]:
            out[key] = [str(item) for item in args[key]]
    return out


def _plugin_args(args: dict[str, Any]) -> dict[str, Any]:
    name = str(args.get("name") or "").strip()
    purpose = str(args.get("purpose") or "").strip()
    if not name or not purpose:
        raise GatewayError("create_plugin needs name and purpose")
    ops = [str(op).strip() for op in args.get("operations") or [] if str(op).strip()]
    brief = [f"Plugin '{name}' for this space: {purpose}",
             "Build it as a lasting tool: a server with a clear API that people (through its UI) "
             "and agents (through its operations) call."]
    if ops:
        brief.append("Operations:\n" + "\n".join(f"- {op}" for op in ops))
    if str(args.get("ui") or "").strip():
        brief.append("UI: " + str(args["ui"]).strip())
    brief.append("Include tests for every operation.")
    return {"brief": "\n\n".join(brief), "title": name}


def _ask(args: dict[str, Any]) -> str:
    question = str(args.get("question") or "").strip()
    if not question:
        return "ask_user needs a question"
    options = [str(item) for item in args.get("options") or [] if str(item).strip()][:8]
    home = Path(env("ASEMAN_ENGINE_HOME"))
    thread = env("ASEMAN_ENGINE_THREAD")
    path = pause_path(home, thread)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"thread": thread, "question": question, "options": options}), encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return "Asked. Stop now and end your turn with the question; the conversation continues with the answer."


def _content_text(result: dict[str, Any]) -> str:
    parts = [str(c.get("text", "")) for c in result.get("content") or [] if isinstance(c, dict)]
    return _clip("\n".join(p for p in parts if p).strip() or "(empty)")


def _clip(value: Any) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str, ensure_ascii=False)
    return text if len(text) <= RESULT_MAX_CHARS else text[:RESULT_MAX_CHARS] + "\n[… clipped]"


# --- stdio JSON-RPC -------------------------------------------------------------


def handle(bridge: Bridge, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    mid = message.get("id")
    if method == "initialize":
        params = message.get("params") or {}
        requested = str(params.get("protocolVersion") or "")
        version = requested if requested in SUPPORTED_PROTOCOLS else DEFAULT_PROTOCOL
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "aseman", "version": "1.0.0"},
            "instructions": "Aseman's space, team, memory and app-generation tools for this turn.",
        }}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": bridge.tools()}}
    if method == "tools/call":
        params = message.get("params") or {}
        text, error = bridge.call(str(params.get("name") or ""), params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}], "isError": error}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method in ("resources/list", "resources/templates/list", "prompts/list"):
        key = {"resources/list": "resources", "resources/templates/list": "resourceTemplates"}.get(method, "prompts")
        return {"jsonrpc": "2.0", "id": mid, "result": {key: []}}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}}


def serve(bridge: Bridge) -> None:
    for line in sys.stdin.buffer:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or "id" not in message:
            continue
        reply = handle(bridge, message)
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


def main() -> None:
    url, token = env("ASEMAN_ENGINE_GATEWAY"), env("ASEMAN_ENGINE_TOKEN")
    if not url or not token:
        print("the aseman MCP server needs ASEMAN_ENGINE_GATEWAY and ASEMAN_ENGINE_TOKEN", file=sys.stderr)
        raise SystemExit(2)
    gateway = Gateway(url, token)
    bridge = Bridge(gateway)
    try:
        serve(bridge)
    finally:
        gateway._sync.close()


if __name__ == "__main__":
    main()
