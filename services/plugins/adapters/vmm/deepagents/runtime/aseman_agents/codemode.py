"""Cloudflare Code Mode — the agent's capability-calling system.

Instead of loading every app function, platform tool and timeline query into
the model context, agents write JavaScript against one OpenAPI document. The
node serves a built-in MCP server at ``{gateway}/codemode/mcp`` with two tools:

* ``search`` — run code against ``codemode.spec()`` (the OpenAPI document)
* ``execute`` — same, plus ``codemode.request({method, path, body})``

Paths in the document:

* ``POST /apps/{slug}/{function}`` — connected apps
* ``POST /platform/{tool}`` — files, proxies, routines, desk, UI, database, …
* ``POST /timeline/{tool}`` — project timeline reads
* ``POST /sandbox/{op}`` — the shared computer (exec, write_files, read_files, …)
* ``POST /agents/{name}`` — the space's agents as subagents, mid-script

Generated code runs in an isolated sandbox on the node; intermediate results
never enter the model context. Messaging, ``ask_user``, sandbox FS/shell,
planning and swarm stay as native LLM tools (harness / interrupts / UX).
"""

from __future__ import annotations

import itertools
import logging
from typing import Any

from langchain_core.tools import BaseTool, StructuredTool

from .context import TurnContext
from .gateway import GatewayError

log = logging.getLogger("aseman.agents")

# MCP wire names → agent-facing names (prefix avoids colliding with other tools).
TOOL_NAMES = {
    "search": "codemode_search",
    "execute": "codemode_execute",
}

RESULT_MAX_CHARS = 12_000
_ids = itertools.count(1)

CODEMODE_PROMPT = """\
<code_mode>
Cloudflare Code Mode (`codemode_search` / `codemode_execute`) is how you call
capabilities of this space — connected apps, platform tools, the shared
computer, the project timeline and the space's other agents. They are **not**
offered as one LLM tool per function.

The MCP server exposes `search` and `execute`; this agent sees them as
`codemode_search` / `codemode_execute` so names stay unique among harness tools.

Write JavaScript that discovers and calls them, composes multiple calls, and
returns only the final result — intermediates stay out of context.

1. `codemode_search` with code that inspects `codemode.spec()` (OpenAPI of
   `/apps/…`, `/platform/…`, `/timeline/…`, `/sandbox/…`, `/agents/…`) and
   returns the paths you need. Skip it when you already know the paths.
2. `codemode_execute` with code that calls
   `codemode.request({method:"POST", path:"…", body:{…}})`:
   - `/apps/{slug}/{function}` — connected app microtools
   - `/platform/{tool}` — e.g. `file_send`, `ui_present`, `proxy_create`, `appui_create`,
     `appui_publish`, `desk_*`, `routine_*`, `db_*`
   - `/timeline/{tool}` — e.g. `find_entities`, `timeline`, `changes`
   - `/sandbox/{op}` — the shared computer: `exec` {command, cwd} → {exit_code, output};
     `write_files` {dir, files:[{path, content}]}; `read_files` {dir, paths} → {path: text};
     `edit_file` {path, old, new}; `list`; `delete`
   - `/agents/{name}` {task} — the space's agents as subagents: the agent does the
     task (in the room, on the shared computer) and you get {agent, answer} back
     in the middle of your code, to branch on or pass to the next call
   `codemode.batch([{path, body}, …])` runs independent calls at the same time
   and returns `[{ok, result} | {ok:false, error}]` in order. A failing
   `codemode.request` throws: catch it to retry, fix or report it.

## One shot first
Each model step re-reads the whole conversation; one execute that does the job
costs a fraction of many small steps. So for any straightforward job, write
one `codemode_execute` that does all of it — create every file, run the tests
and checks, react to their results in code (retry, fix, branch), call the apps,
platform tools and agents it needs, publish or deliver — and return a short
report: what was done, exit codes, failures with the relevant output lines,
paths. Read what you need first (also in one call), then act in one call. Fall
back to separate steps only when a step needs your judgement on a result you
cannot check in code, or a person must answer (`ask_user`).

Do not invent direct `app__function`, `file_send`, `appui_create` or
`timeline_*` tools — use Code Mode. Messaging (`send_message`, …), `ask_user`,
`read_attachment` (files and images people attach: it shows you the picture),
the native sandbox files/shell (`execute`, `read_file`, … — `read_file` also
shows you screenshots), `write_todos` and `task` / swarm remain native tools.
</code_mode>"""


async def rpc(ctx: TurnContext, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": next(_ids), "method": method}
    if params is not None:
        message["params"] = params
    reply = await ctx.gateway.codemode(message)
    if reply.get("error"):
        err = reply["error"]
        raise GatewayError(f"codemode {method}: {err.get('message') if isinstance(err, dict) else err}")
    return reply.get("result") or {}


def _text(result: dict[str, Any]) -> str:
    parts = [str(c.get("text", "")) for c in result.get("content") or [] if isinstance(c, dict)]
    text = "\n".join(p for p in parts if p).strip() or "(empty)"
    if len(text) > RESULT_MAX_CHARS:
        text = text[:RESULT_MAX_CHARS].rstrip() + "\n[… cut: return less from your code]"
    if result.get("isError"):
        return "Code Mode error: " + text
    return text


def _tool(ctx: TurnContext, spec: dict[str, Any]) -> BaseTool:
    mcp_name = spec["name"]
    schema = spec.get("inputSchema") or {"type": "object", "properties": {}}
    schema = {**schema, "type": "object"}
    schema.setdefault("properties", {})

    async def run(**kwargs: Any) -> str:
        args = {k: v for k, v in kwargs.items() if v is not None}
        try:
            return _text(await rpc(ctx, "tools/call", {"name": mcp_name, "arguments": args}))
        except GatewayError as exc:
            return f"Code Mode is unavailable right now: {exc}"

    return StructuredTool(
        name=TOOL_NAMES[mcp_name],
        description=(spec.get("description") or mcp_name).strip(),
        args_schema=schema,
        coroutine=run,
    )


async def codemode_tools(ctx: TurnContext) -> list[BaseTool]:
    """Code Mode search/execute tools; empty when the gateway cannot list them."""
    try:
        result = await rpc(ctx, "tools/list")
    except Exception as exc:  # noqa: BLE001
        log.warning("codemode unavailable for space %s: %s", ctx.space, exc)
        return []
    tools = [t for t in result.get("tools") or [] if isinstance(t, dict) and t.get("name") in TOOL_NAMES]
    return [_tool(ctx, spec) for spec in tools]
