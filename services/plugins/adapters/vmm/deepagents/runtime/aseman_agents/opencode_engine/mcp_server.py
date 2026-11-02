"""Stdio MCP bridge between an OpenCode process and the turn gateway.

Space tools mirror Deep Agents' room tools (messaging, team, spaces.ask,
recruit/hire). ``platform_call`` remains an escape hatch. Also: ask_user,
assemble_team, run_swarm. Model calls are not proxied: OpenCode talks to its
own free-model gateway. Programmer actions are refused.
"""

from __future__ import annotations

import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from aseman_agents.gateway import Gateway, GatewayError

from . import config as configlib
from . import space_tools
from .cli import RunResult, RunSpec, pause_path
from .mapping import APP_AGENT, reject_programmer
from .models import binary, role_for, select


SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2024-11-05"

def _space_tool_names() -> set[str]:
    # Room tools always; personal tools when ASEMAN_ENGINE_MODE=personal.
    return {t["name"] for t in space_tools.space_tool_defs()}


def serve(gateway: Gateway) -> None:
    for message in _messages(sys.stdin.buffer):
        # Notifications (no id) need no reply; requests do.
        if not isinstance(message, dict) or "id" not in message:
            continue
        reply = _handle(gateway, message)
        if reply is not None:
            _write(reply)


def _handle(gateway: Gateway, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    mid = message.get("id")
    if method == "initialize":
        params = message.get("params") or {}
        requested = str(params.get("protocolVersion") or "")
        version = requested if requested in SUPPORTED_PROTOCOLS else DEFAULT_PROTOCOL
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "aseman-opencode-engine", "version": "1.0.0"},
        }}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": _tools()}}
    if method == "tools/call":
        params = message.get("params") or {}
        text, error = _call(gateway, str(params.get("name") or ""), params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": text}], "isError": error,
        }}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}}


def _tools() -> list[dict[str, Any]]:
    obj = {"type": "object"}
    # Prefer named space tools (same surface as Deep Agents). platform_call last.
    return space_tools.space_tool_defs() + [
        {"name": "ask_user", "description": "Ask the person a question and pause until they answer.",
         "inputSchema": {**obj, "properties": {
             "question": {"type": "string"},
             "options": {"type": "array", "items": {"type": "string"}},
         }, "required": ["question"]}},
        {"name": "assemble_team", "description": (
            "Register OpenCode subagents for roles that are not on the team yet. "
            "Hand each one work with the task tool, or run_swarm."
        ), "inputSchema": {**obj, "properties": {
            "agents": {"type": "array", "items": {"type": "object"}},
        }, "required": ["agents"]}},
        {"name": "run_swarm", "description": (
            "Run independent tasks at the same time, each as its own headless opencode run."
        ), "inputSchema": {**obj, "properties": {
            "goal": {"type": "string"},
            "tasks": {"type": "array", "items": {"type": "object"}},
        }, "required": ["tasks"]}},
        {"name": "platform_call", "description": (
            "Escape hatch: call one Aseman platform action by namespace/action when no "
            "named space tool fits. Prefer send_message, read_room, list_team, "
            "list_space_tools, call_space_tool, recruit_agent, hire_agent. Never an LLM "
            "call, and never opencode_run / appui_create."
        ), "inputSchema": {**obj, "properties": {
            "namespace": {"type": "string"},
            "action": {"type": "string"},
            "body": {"type": "object"},
        }, "required": ["namespace", "action"]}},
    ]


def _call(gateway: Gateway, name: str, args: dict[str, Any]) -> tuple[str, bool]:
    try:
        if name in _space_tool_names():
            return space_tools.call_space_tool(gateway, name, args if isinstance(args, dict) else {})
        if name == "platform_call":
            return _platform(gateway, args)
        if name == "ask_user":
            return _ask(args), False
        if name == "assemble_team":
            return _assemble(args), False
        if name == "run_swarm":
            return _swarm(args), False
    except GatewayError as exc:
        return str(exc), True
    except Exception as exc:  # noqa: BLE001 - the tool result is the error
        return f"{type(exc).__name__}: {exc}", True
    return f"unknown tool {name}", True


def _platform(gateway: Gateway, args: dict[str, Any]) -> tuple[str, bool]:
    namespace = str(args.get("namespace") or "").strip()
    action = str(args.get("action") or "").strip()
    body = args.get("body") if isinstance(args.get("body"), dict) else {}
    reason = reject_programmer(namespace, action, body)
    if reason:
        return reason, True
    if not namespace or not action:
        return "platform_call needs namespace and action", True
    result = gateway.call_sync(namespace, action, body)
    return json.dumps(result, default=str)[:20000], False


def _ask(args: dict[str, Any]) -> str:
    question = str(args.get("question") or "").strip()
    if not question:
        return "ask_user needs a question"
    options = [str(item) for item in args.get("options") or [] if str(item).strip()][:8]
    home = Path(os.environ.get("ASEMAN_ENGINE_HOME", ""))
    thread = os.environ.get("ASEMAN_ENGINE_THREAD", "")
    path = pause_path(home, thread)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"thread": thread, "question": question, "options": options}), encoding="utf-8")
    try:
        # The question may be private to the thread; nobody else needs to read it.
        os.chmod(path, 0o600)
    except OSError:
        pass
    return "Paused until the person answers. Do not keep working."


def _assemble(args: dict[str, Any]) -> str:
    """Register subagents in the engine config so the next run and run_swarm load them."""
    config_path = Path(os.environ["ASEMAN_ENGINE_CONFIG"])
    home = Path(os.environ["ASEMAN_ENGINE_PROCESS_HOME"])
    model = os.environ.get("ASEMAN_ENGINE_MODEL") or select("specialist")
    doc = json.loads(config_path.read_text(encoding="utf-8"))
    agents = doc.setdefault("agent", {})
    written = []
    for raw in (args.get("agents") or [])[:16]:
        if not isinstance(raw, dict) or not str(raw.get("name") or "").strip():
            continue
        agent = configlib.teammate(
            str(raw["name"]), str(raw.get("description") or ""), str(raw.get("instructions") or ""),
            model, primary=False,
        )
        agents[agent.name] = {
            "description": agent.description, "mode": "subagent", "model": agent.model,
            "prompt": agent.prompt, "permission": configlib.permission(),
        }
        directory = home / ".config" / "opencode" / "agents"
        directory.mkdir(parents=True, exist_ok=True)
        configlib._markdown(directory / f"{agent.name}.md", agent)
        written.append(agent.name)
    if not written:
        return "No agents registered. Pass agents: [{name, description, instructions}]."
    config_path.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    return ("Registered " + ", ".join(written)
            + ". Hand one a task with the task tool, or several with run_swarm.")


def _swarm(args: dict[str, Any]) -> str:
    if os.environ.get("ASEMAN_ENGINE_SWARM_CHILD") == "1":
        return "A swarm task cannot start another swarm. Finish the task you were given."
    tasks = [task for task in (args.get("tasks") or []) if isinstance(task, dict) and str(task.get("task") or "").strip()]
    if not tasks:
        return "run_swarm needs tasks: [{id, agent, task}]."
    tasks = tasks[:16]
    goal = str(args.get("goal") or "").strip()
    limit = _parallel()
    specs = [_child(task, goal) for task in tasks]
    results: list[str] = []
    with ThreadPoolExecutor(max_workers=min(limit, len(specs))) as pool:
        future_map = {pool.submit(_run_child, spec): spec for spec in specs}
        for future in as_completed(future_map):
            spec = future_map[future]
            try:
                result = future.result()
            except Exception as exc:  # noqa: BLE001
                results.append(f"{spec.agent}: {type(exc).__name__}: {exc}")
                continue
            text = (result.stdout or result.stderr or "").strip()
            results.append(f"{spec.agent}: {text[:2000] or '(no output)'}")
    return "Swarm:\n" + "\n".join(results)


def _child(task: dict[str, Any], goal: str) -> RunSpec:
    name = str(task.get("agent") or "general")
    app = "app" in name.lower()
    model = os.environ.get("ASEMAN_ENGINE_MODEL") or select(role_for(app=app, handoff=not app))
    if app:
        name = APP_AGENT
    else:
        name = configlib.agent_id(name)
    home = Path(os.environ["ASEMAN_ENGINE_PROCESS_HOME"])
    config = Path(os.environ["ASEMAN_ENGINE_CONFIG"])
    directory = os.environ.get("ASEMAN_ENGINE_DIR") or str(home)
    message = str(task["task"]).strip()
    if goal:
        message = f"Goal: {goal}\n\nYour task: {message}\n\nDo this task only. Do not start a swarm."
    return RunSpec(
        binary=binary(), agent=name, model=model, directory=directory, message=message,
        home=home, config=config, title=str(task.get("id") or name)[:80],
        extra_env={"ASEMAN_ENGINE_SWARM_CHILD": "1"},
    )


def _run_child(spec: RunSpec) -> RunResult:
    import subprocess
    try:
        done = subprocess.run(spec.argv(), capture_output=True, text=True, timeout=_timeout(),
                              env=spec.env(), cwd=spec.directory, check=False)
    except FileNotFoundError:
        return RunResult(stdout="", stderr="opencode CLI not found", code=127)
    return RunResult(stdout=done.stdout, stderr=done.stderr, code=done.returncode)


def _parallel() -> int:
    try:
        return max(1, min(int(os.environ.get("ASEMAN_SWARM_PARALLEL") or "8"), 32))
    except ValueError:
        return 8


def _timeout() -> float:
    try:
        return float(os.environ.get("ASEMAN_OPENCODE_ENGINE_TIMEOUT") or "1200")
    except ValueError:
        return 1200.0


def _messages(stream: Any):
    while True:
        line = stream.readline()
        if not line:
            return
        if line.lower().startswith(b"content-length:"):
            try:
                length = int(line.split(b":", 1)[1].strip())
            except (ValueError, IndexError):
                continue
            while True:
                extra = stream.readline()
                if not extra or extra in (b"\r\n", b"\n"):
                    break
            body = stream.read(length)
            if not body:
                return
            try:
                yield json.loads(body)
            except ValueError:
                continue
            continue
        header = line.strip()
        if not header:
            continue
        try:
            yield json.loads(header)
            continue
        except ValueError:
            continue


def _write(message: dict[str, Any]) -> None:
    body = json.dumps(message) + "\n"
    sys.stdout.write(body)
    sys.stdout.flush()


def main() -> None:
    url = os.environ.get("ASEMAN_ENGINE_GATEWAY", "")
    token = os.environ.get("ASEMAN_ENGINE_TOKEN", "")
    if not url or not token:
        print("aseman opencode engine MCP needs ASEMAN_ENGINE_GATEWAY and ASEMAN_ENGINE_TOKEN", file=sys.stderr)
        raise SystemExit(2)
    gateway = Gateway(url, token)
    try:
        serve(gateway)
    finally:
        gateway._sync.close()


if __name__ == "__main__":
    main()
