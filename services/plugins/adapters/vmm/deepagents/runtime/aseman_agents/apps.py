"""Native app-tool deferral — **fallback only**.

Production turns call connected apps through Cloudflare Code Mode, so app
microtools are never listed and this module is a no-op. It still runs when
Code Mode is off or its MCP cannot be listed: each ``app__function`` is a
native LLM tool, and when there are more than ``DEFER_ABOVE`` they are
deferred (``load_app_tools``) the way Claude Code defers MCP tools.
"""

from __future__ import annotations

from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage
from langchain_core.tools import BaseTool, StructuredTool

#: More app functions than this, and they are loaded on demand.
DEFER_ABOVE = 24
LOAD_TOOL = "load_app_tools"


def app_of(name: str) -> str:
    """The connected app a tool is a function of, or "" for a tool of its own."""
    app, sep, function = name.partition("__")
    return app if sep and app and function else ""


def _name(tool: Any) -> str:
    if isinstance(tool, dict):
        return str(tool.get("name") or (tool.get("function") or {}).get("name") or "")
    return str(getattr(tool, "name", "") or "")


def apps(tools: list[BaseTool]) -> dict[str, list[BaseTool]]:
    """The agent's app functions, by app."""
    out: dict[str, list[BaseTool]] = {}
    for t in tools:
        app = app_of(t.name)
        if app:
            out.setdefault(app, []).append(t)
    return out


def loaded(messages: list[Any]) -> set[str]:
    """The apps the conversation loaded or used."""
    out: set[str] = set()
    for m in messages:
        if not isinstance(m, AIMessage):
            continue
        for call in m.tool_calls or []:
            if call.get("name") == LOAD_TOOL:
                out |= {str(a).strip() for a in (call.get("args") or {}).get("apps") or []}
            elif app_of(call.get("name", "")):
                out.add(app_of(call["name"]))
    return out


def _about(functions: list[BaseTool]) -> str:
    # An app function's description starts "[App name] what it does".
    first = " ".join((functions[0].description or "").split())
    title = first[1:].split("]", 1)[0] if first.startswith("[") else ""
    names = ", ".join(t.name.partition("__")[2] for t in functions)
    if len(names) > 500:
        names = names[:500].rsplit(",", 1)[0] + ", …"
    return f"{title + ': ' if title else ''}{len(functions)} functions: {names}"


def load_tool(groups: dict[str, list[BaseTool]]) -> BaseTool:
    listing = "\n".join(f"- {app} ({_about(functions)})" for app, functions in sorted(groups.items()))

    def run(apps: list[str]) -> str:
        known = [a for a in apps if a in groups]
        unknown = [a for a in apps if a not in groups]
        if not known:
            return f"error: no such app ({', '.join(unknown) or 'none given'}). The apps: {', '.join(sorted(groups))}."
        text = "; ".join(f"{a}: {', '.join(t.name for t in groups[a])}" for a in known)
        note = f" Unknown: {', '.join(unknown)}." if unknown else ""
        return f"Loaded {text}. Call these functions directly from your next step.{note}"

    return StructuredTool.from_function(
        func=run, name=LOAD_TOOL,
        description=("Load the functions of the space's connected apps so you can call them; their schemas are "
                     "offered from your next step. Load every app the work needs in one call.\n\nApps:\n" + listing))


class AppTools(AgentMiddleware):
    """Offers the functions of the apps the conversation loaded, and the rest of the tools."""

    def __init__(self, deferred: set[str]) -> None:
        super().__init__()
        self.deferred = deferred

    def _request(self, request: Any) -> Any:
        hidden = self.deferred - loaded(request.messages)
        if not hidden:
            return request
        return request.override(tools=[t for t in request.tools or [] if app_of(_name(t)) not in hidden])

    def wrap_model_call(self, request: Any, handler: Any) -> Any:
        return handler(self._request(request))

    async def awrap_model_call(self, request: Any, handler: Any) -> Any:
        return await handler(self._request(request))


def deferral(tools: list[BaseTool]) -> tuple[list[BaseTool], list[AgentMiddleware]]:
    """The load tool and its middleware when the agent has many app functions; else nothing."""
    groups = apps(tools)
    if sum(len(f) for f in groups.values()) <= DEFER_ABOVE:
        return [], []
    return [load_tool(groups)], [AppTools(set(groups))]
