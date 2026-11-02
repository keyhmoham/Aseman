"""How Aseman's agentic work lands on OpenCode's headless CLI.

The programmer OpenCode (Admin → OpenCode) is a different switch: it builds
apps inside a Deep Agents turn, on the metered platform gateway. Nothing
here calls that path.
"""

from __future__ import annotations

# platform mechanism → the OpenCode command or tool that does it.
MECHANISMS: tuple[tuple[str, str], ...] = (
    ("Agent turn", "opencode run --format json --auto, one session per agent per room"),
    ("Agent team", "OpenCode agents: primary for whoever is on the turn, subagents for teammates"),
    ("Task handoff", "the task tool, or opencode run --agent for that teammate"),
    ("Swarm", "parallel opencode run processes, one per task, started together"),
    ("App generation", "the aseman-app-builder subagent, platform file tools, then appui_publish"),
    ("Planning", "todowrite"),
    ("Questions to people", "the ask_user tool; the session waits for the answer"),
    ("Messaging", "send_message / read_room / send_direct_message / read_direct_messages (turn gateway)"),
    ("Team & space tools", "list_team, list_space_tools, call_space_tool → spaces.ask (same as Deep Agents)"),
    ("Recruit / hire", "recruit_agent, list_marketplace, hire_agent"),
    ("Other platform actions", "platform_call escape hatch on the turn gateway (never /llm)"),
    ("Models", "a free opencode/* model on OpenCode's own gateway, chosen for the role"),
)

APP_AGENT = "aseman-app-builder"

# Programmer tools. The engine refuses them so the two mechanisms stay apart.
PROGRAMMER_ACTIONS = ("opencode_run", "opencode_status", "opencode_models", "appui_create")


def brief() -> str:
    """A short reminder pinned to every OpenCode turn."""
    lines = ["You are running as Aseman's agent, through the OpenCode CLI.", "Mechanisms:"]
    lines += [f"- {name}: {how}" for name, how in MECHANISMS]
    lines.append(
        "Your model is a free model on OpenCode's own gateway. Ignore any platform "
        "provider or model named on your profile. Do not call the platform LLM proxy."
    )
    lines.append(
        "App building here is the aseman-app-builder agent (sandbox files, then "
        "appui_publish). Do not call opencode_run, opencode_status, opencode_models, "
        "appui_create, or aseman-appui. That programmer path is a different switch "
        "and uses a different model gateway."
    )
    lines.append(
        "Use the named space tools (send_message, read_room, list_team, list_space_tools, "
        "call_space_tool, recruit_agent, …) the same way a Deep Agents turn uses its "
        "room tools. Prefer them over platform_call."
    )
    return "\n".join(lines)


def reject_programmer(namespace: str, action: str, body: object) -> str:
    """Why this platform call is the other OpenCode, or empty if it may run."""
    if namespace == "llm":
        return "This engine does not use the platform LLM gateway. OpenCode picks a free model itself."
    import json
    blob = json.dumps({"action": action, "body": body}, default=str)
    for name in PROGRAMMER_ACTIONS:
        if action == name or f'"{name}"' in blob:
            return (f"{name} belongs to the programmer OpenCode (aseman-appui on the platform "
                    "LLM gateway), not this engine. Hand the app to aseman-app-builder, "
                    "write it with sandbox file tools, then appui_publish.")
    return ""
