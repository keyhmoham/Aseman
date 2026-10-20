"""Keeping a turn's context small without making the agent less capable.

Every model call of a turn carries the whole context again, so what a turn
costs is (fixed prompt + conversation so far) x (number of model calls). This
module works on each of those:

* the fixed prompt — shorter wording for the harness's planning, skills and
  file-tool instructions, with the same rules;
* the conversation — old tool output is trimmed to its opening lines and old
  screenshots and attached pictures are dropped once the agent has moved on,
  big tool results go to a file sooner, and the history is summarized well
  before the model's window is full (with or without a sandbox); both start at
  a share of the model's window, so a model with a large window keeps more of
  what it read. Instructions the agent read (an app's instructions or help, a
  skill) are never trimmed: an agent that loses how to work reads it again,
  and again;
* the count — tokens are estimated conservatively (code, JSON and ids take far
  more tokens than four characters each), so summarizing starts before the
  window is full;
* the prefix stays byte-identical from one call to the next (edits only ever
  touch a message once), so the provider's prompt cache keeps hitting.
"""

from __future__ import annotations

import json
import os
from typing import Any

from deepagents.backends import StateBackend
from deepagents.backends.utils import sanitize_tool_call_id
from deepagents.middleware.filesystem import FilesystemMiddleware
from deepagents.middleware.skills import SkillsMiddleware
from deepagents.middleware.summarization import SummarizationMiddleware
from langchain.agents.middleware import AgentMiddleware, TodoListMiddleware
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from langchain_core.messages.utils import count_tokens_approximately

from .guard import reference

# --- the fixed prompt --------------------------------------------------------

TODO_PROMPT = """\
## Planning
For work of three or more distinct steps, keep a plan with `write_todos`: mark a
step in_progress before you start it and completed as soon as it is done, and
revise the plan when you learn something. Skip it for simple requests. Never
call it twice in one step. Write your final answer after your last
`write_todos` call, not together with it."""

TODO_TOOL = """\
Create or replace your plan: the full list of steps, each `pending`,
`in_progress` or `completed`. Use it for work of three or more steps; keep one
step in_progress, mark steps completed as you finish them, and add or remove
steps as the work changes. Not for simple requests."""

SKILLS_PROMPT = """\
## Skills
Skills are instructions for kinds of work, kept as files.

{skills_locations}{skills_load_warnings}

Available skills:

{skills_list}

When a task matches a skill's description, read its SKILL.md first
(`read_file` with `limit=1000`) and follow it; its scripts and reference files
are next to it (use absolute paths)."""

FILE_TOOLS = {
    "ls": "List the files in a directory (absolute path).",
    "read_file": (
        "Read a file (absolute path). Returns up to `limit` lines (default 100) from `offset`; page through large "
        "files. A `@@ ... @@` status header precedes the content and is not part of the file. Images, audio, video "
        "and PDFs are returned for you to see (pass only `file_path`). Read several files in one step when you "
        "need them. Read a file before you edit it."
    ),
    "write_file": "Create a file or replace it entirely (absolute path). To change part of a file use edit_file.",
    "edit_file": (
        "Replace exact text in a file you have read. `old_string` must match the file exactly, indentation "
        "included, and be unique unless `replace_all` is true. Never include the read status header."
    ),
    "glob": (
        "Find files by glob pattern; returns absolute paths. `*.py` matches that name at any depth, a pattern with "
        "`/` matches the path from the search root (`src/**/*.py`), `{a,b}` and `[abc]` work. Dot-files match only "
        "when the pattern segment starts with a dot."
    ),
    "grep": (
        "Search files for LITERAL text (not regex: `a|b` and `.*` match those characters). For regex run "
        "`rg '<regex>'` with execute. `glob` limits which files are searched; `output_mode` chooses file names, "
        "matching lines or counts."
    ),
    "execute": (
        "Run a shell command on the space's computer; returns stdout and stderr with the exit code. Chain with "
        "`&&` or `;`, use absolute paths, quote paths with spaces. Prefer glob/grep/read_file over find/grep/cat."
    ),
}

# --- the conversation --------------------------------------------------------

# Trim old tool output once the conversation is this large (estimated tokens);
# a turn trims at half its summarization size instead (see trim_above).
# Not too early: an agent that loses what it just read reads it again.
TRIM_ABOVE = 24_000
# The newest tool results are always kept whole.
KEEP_RESULTS = 8
# What is left of a trimmed result: enough to remember what it was.
KEEP_CHARS = 400
# Screenshots and other media the agent can still see.
KEEP_MEDIA = 2
# Answers the agent cannot get again by re-running a tool.
NEVER_TRIM = frozenset({"task", "wait_tasks", "check_tasks", "ask_user", "write_todos", "assemble_team", "run_swarm"})
# Instructions the agent read stay whole up to this size (characters); a larger
# result went to a file, and the parts of it the agent reads stay whole instead.
PIN_MAX_CHARS = 24_000

# Summarize the history at this share of the model's window (at the most
# TRADERA_SUMMARIZE_MAX_TOKENS, when set, to bound what a call costs).
SUMMARIZE_SHARE = 0.6
SUMMARY_KEEPS = 12_000
# The window assumed for a model nobody told the runtime about.
DEFAULT_WINDOW = 128_000
# Characters per token when estimating the size of a call.
CHARS_PER_TOKEN = 3.0
# A tool result larger than this goes to a file; the agent gets a preview.
RESULT_TO_FILE_ABOVE = 6_000

_MEDIA_TYPES = frozenset({"image", "image_url", "audio", "video", "file", "input_image", "input_audio"})
_MEDIA_GONE = "[picture removed from context to save space: read the file again if you need to see it]"
_ATTACHED_GONE = "[attached picture removed from context to save space: read the attachment again if you need it]"


def count_tokens(messages: Any, *, tools: Any = None) -> int:
    """A conservative token estimate of a model call: three characters a token
    rather than four, since code, JSON, ids and non-Latin text take more tokens
    than prose (the provider's own count is often twice the four-character
    estimate on such content)."""
    return count_tokens_approximately(list(messages), chars_per_token=CHARS_PER_TOKEN, tools=tools)


def window_of(model: Any) -> int:
    """The model's input window: its profile, else the node's default."""
    window = (getattr(model, "profile", None) or {}).get("max_input_tokens")
    if isinstance(window, int) and not isinstance(window, bool) and window > 0:
        return window
    try:
        return int(os.environ.get("TRADERA_DEFAULT_CONTEXT_WINDOW", "") or DEFAULT_WINDOW)
    except ValueError:
        return DEFAULT_WINDOW


def summarize_above(model: Any) -> int:
    above = int(window_of(model) * SUMMARIZE_SHARE)
    try:
        cap = int(os.environ.get("TRADERA_SUMMARIZE_MAX_TOKENS", "") or 0)
    except ValueError:
        cap = 0
    return max(4_000, min(above, cap) if cap > 0 else above)


def trim_above(summarize: int) -> int:
    """Where old tool output starts being trimmed: half way to summarizing."""
    return summarize // 2


def summary_keeps(summarize: int) -> int:
    """How much of the latest history a summary keeps as it is."""
    return min(summarize // 3, max(SUMMARY_KEEPS, summarize // 4))


def _is_media(block: Any) -> bool:
    return isinstance(block, dict) and block.get("type") in _MEDIA_TYPES


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content if not _is_media(b))
    return str(content)


def pinned(messages: list[Any]) -> set[str]:
    """The tool results kept whole however large the conversation: the latest
    read of each set of instructions (see guard.reference), and what the agent
    read of one that was too large and went to a file."""
    calls = {c.get("id", ""): c for m in messages if isinstance(m, AIMessage) for c in m.tool_calls or []}
    sizes = {m.tool_call_id: len(_text_of(m.content)) for m in messages if isinstance(m, ToolMessage)}
    refs = [c for c in calls.values() if reference(c)]
    captures = [sanitize_tool_call_id(c["id"]) for c in refs if c.get("id")]
    latest: dict[str, str] = {}
    for call in calls.values():
        path = str((call.get("args") or {}).get("file_path", "")) if call.get("name") == "read_file" else ""
        captured = bool(path) and "large_tool_results" in path and any(cid in path for cid in captures)
        if (reference(call) or captured) and sizes.get(call.get("id", ""), 0) <= PIN_MAX_CHARS:
            # Read again: only the newest copy stays whole.
            key = call.get("name", "") + json.dumps(call.get("args") or {}, sort_keys=True, default=str)
            latest[key] = call.get("id", "")
    return set(latest.values())


def diet(messages: list[Any], trim_above: int = TRIM_ABOVE) -> list[Any]:
    """The messages to replace so the conversation carries less.

    Each message is changed at most once and only ever to the same text, so the
    part of the conversation before it stays identical between model calls.
    """
    results = [m for m in messages if isinstance(m, ToolMessage)]
    changed: dict[int, Any] = {}

    def mark(msg: Any, content: Any, key: str) -> None:
        meta = {**(changed.get(id(msg), msg).response_metadata or {}), key: True}
        changed[id(msg)] = changed.get(id(msg), msg).model_copy(update={"content": content, "response_metadata": meta})

    with_media = [m for m in results if isinstance(m.content, list) and any(_is_media(b) for b in m.content)]
    for msg in with_media[:-KEEP_MEDIA] if KEEP_MEDIA else with_media:
        kept = [b for b in msg.content if not _is_media(b)]
        mark(msg, [*kept, {"type": "text", "text": _MEDIA_GONE}], "media_dropped")

    # Pictures attached to earlier messages from people: the newest one keeps its own.
    people = [m for m in messages if isinstance(m, HumanMessage)]
    for msg in people[:-1]:
        if isinstance(msg.content, list) and any(_is_media(b) for b in msg.content):
            kept = [b for b in msg.content if not _is_media(b)]
            mark(msg, [*kept, {"type": "text", "text": _ATTACHED_GONE}], "media_dropped")

    if count_tokens(messages) > trim_above:
        keep = pinned(messages)
        for msg in results[:-KEEP_RESULTS] if KEEP_RESULTS else results:
            if msg.name in NEVER_TRIM or msg.tool_call_id in keep or (msg.response_metadata or {}).get("trimmed"):
                continue
            current = changed.get(id(msg), msg)
            text = _text_of(current.content)
            if len(text) <= KEEP_CHARS * 2:
                continue
            head = text[:KEEP_CHARS].rstrip()
            mark(msg, f"{head}\n… [{len(text) - len(head)} more characters trimmed from context. You already "
                      "used this result; run the tool again only if you need its exact text]", "trimmed")
    return [m for m in changed.values() if m.id]


class ContextDiet(AgentMiddleware):
    """Trims old tool output and drops old screenshots before each model call."""

    def __init__(self, trim_above: int = TRIM_ABOVE) -> None:
        super().__init__()
        self.trim_above = trim_above

    def before_model(self, state: Any, runtime: Any) -> dict[str, Any] | None:
        updates = diet(list(state.get("messages") or []), self.trim_above)
        return {"messages": updates} if updates else None

    async def abefore_model(self, state: Any, runtime: Any) -> dict[str, Any] | None:
        return self.before_model(state, runtime)


def planning() -> AgentMiddleware:
    return TodoListMiddleware(system_prompt=TODO_PROMPT, tool_description=TODO_TOOL)


def middleware(model: Any, backend: Any, *, skills: list[str] | None) -> list[AgentMiddleware]:
    """The context-keeping middleware of a turn. The ones that share a name with
    the harness's defaults replace them."""
    above = summarize_above(model)
    stack: list[AgentMiddleware] = [planning(), ContextDiet(trim_above=trim_above(above))]
    summarization = SummarizationMiddleware(
        # Without a sandbox the history goes to the thread's own state.
        model, backend=backend if backend is not None else StateBackend(), token_counter=count_tokens,
        trigger=("tokens", above), keep=("tokens", summary_keeps(above)),
        truncate_args_settings={"trigger": ("tokens", above // 2), "keep": ("messages", 8), "max_length": 1000},
    )
    if backend is None:
        return [*stack, summarization]
    stack += [
        FilesystemMiddleware(backend=backend, custom_tool_descriptions=FILE_TOOLS,
                             tool_token_limit_before_evict=RESULT_TO_FILE_ABOVE),
        summarization,
    ]
    if skills:
        stack.append(SkillsMiddleware(backend=backend, sources=skills, system_prompt=SKILLS_PROMPT))
    return stack
