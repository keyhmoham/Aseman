"""How Aseman's agentic work lands on DeepSeek Harness (``dsh``).

DeepSeek Harness is an all-plugin Cordis agent harness: the model adapter,
tool registry, session log and agent loop are plugins composed by a profile.
The engine boots the shipped ``headless`` profile with one patch overlay per
turn (profile.py). The harness brings its own agentic modules — the loop,
its own memory (the aseman-memory dsh plugin, read in by dsh's instruction
loader), its own swarm (subagents, Agent Teams, workflows), planning and
goals — and the overlay wires them to the platform: the LLM route on the
turn gateway, and the Aseman MCP bridge (space tools, timeline, Code Mode,
questions, hand-offs to Aseman agents, app/plugin creation).

The model runs on the platform's metered LLM gateway by default (the
agent's own provider and model, billed on the turn).
"""

from __future__ import annotations

# platform mechanism → the DeepSeek Harness plugin or tool that does it.
MECHANISMS: tuple[tuple[str, str], ...] = (
    ("Agent turn", "dsh --profile headless --json with an Aseman patch overlay; one dsh Session per agent per thread (--session-id)"),
    ("Agentic loop", "@deepseek-ai/dsh-agent-loop, with guard, compaction and retry plugins from the headless profile"),
    ("Models", "llm-pi-ai route 'aseman' → the platform LLM gateway (agent's provider/model, metered on the turn); or llm-deepseek with the engine's own DeepSeek key"),
    ("Subagents", "dsh's own subagent / subagent_fork tools (in-process children), steered with send_message / wait_agent / list_agents"),
    ("Swarm", "dsh's own: several subagents started at once (each returns its id at once), collected with wait_agent; shown in the agent's work log"),
    ("Agent team", "dsh's own Agent Teams task board (team_task_*) for leads (dsh 0.2.2+), plus the space's Aseman agents as teammates"),
    ("Task handoff / dispatch", "delegate_task on the Aseman MCP bridge: a room task to another Aseman agent, its own turn answers back"),
    ("Planning & workflow", "dsh's own todo_write, plan mode (exit_plan_mode), goals (create_goal) and the workflow tool; todos go to the work log"),
    ("Questions to people", "ask_user on the Aseman MCP bridge; the run ends, the question waits in Aseman, the dsh Session resumes with the answer"),
    ("Memory", "dsh's own: the aseman-memory plugin (memory_remember / memory_search / memory_read / memory_rewrite, a per-turn journal) over a per-space, per-agent store; dsh's agent-instructions loader puts the notes in every turn"),
    ("Timeline & Code Mode", "the turn gateway's timeline and Code Mode MCP servers, forwarded by the Aseman MCP bridge"),
    ("Messaging & space tools", "send_message, read_room, list_team, list_space_tools, call_space_tool, … (same actions as Deep Agents)"),
    ("Recruit / hire", "recruit_agent, list_marketplace, hire_agent"),
    ("Creator mode / plugin creation", "create_app / create_plugin → Aseman's on-demand app generation (appui_create, appui_publish)"),
    ("Other platform actions", "platform_call escape hatch on the turn gateway (never /llm)"),
)

APP_BUILDER = "aseman-app-builder"

# Self-modification of the shared runtime is not an agent's to do: plugins are
# Aseman apps, created through the platform, not npm packages in the runtime.
RUNTIME_ACTIONS = ("plugin_manager", "plugin_market", "install_bundle")


def brief() -> str:
    """The reminder pinned to every DeepSeek Harness turn."""
    lines = ["You are running as Aseman's agent on DeepSeek Harness (dsh).", "Mechanisms:"]
    lines += [f"- {name}: {how}" for name, how in MECHANISMS]
    lines.append(
        "Aseman's tools reach you through the 'aseman' MCP server (mcp__aseman__*). "
        "Prefer the named space tools over platform_call."
    )
    lines.append(
        "Your own computer here has no files and no shell for the space: work on the "
        "space's computer and apps through list_space_tools / call_space_tool."
    )
    lines.append(
        "Plugins, apps and tools people use are created through create_app / create_plugin "
        "(Aseman's app generation), never by installing packages into this harness."
    )
    lines.append(
        "Your memory and your swarm are your own (memory_* tools; subagent, wait_agent, "
        "the Team board, workflow). When you need a person's answer, call ask_user and stop: "
        "the conversation continues with their answer."
    )
    return "\n".join(lines)


def reject(namespace: str, action: str, body: object) -> str:
    """Why this platform call may not run from a DeepSeek Harness turn, or ''."""
    if namespace == "llm":
        return "Model calls go through the harness's own LLM route, not platform_call."
    import json
    blob = json.dumps({"action": action, "body": body}, default=str)
    for name in RUNTIME_ACTIONS:
        if action == name or f'"{name}"' in blob:
            return (f"{name} would change the shared agent runtime. Create the plugin as an "
                    "Aseman app with create_plugin instead.")
    return ""
