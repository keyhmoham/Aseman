"""First-class space tools for the OpenCode MCP bridge.

Mirrors the Deep Agents ``tools.py`` communication and space-tool surface, but
over the turn gateway (same ``spaces.*`` / ``users.*`` / ``market.*`` actions).
OpenCode agents should prefer these named tools; ``platform_call`` remains an
escape hatch for anything else on the allowlist.
"""

from __future__ import annotations

import json
import os
from typing import Any

from aseman_agents.gateway import Gateway, GatewayError


def space() -> str:
    return (os.environ.get("ASEMAN_ENGINE_SPACE") or "").strip()


def room() -> str:
    return (os.environ.get("ASEMAN_ENGINE_ROOM") or "").strip()


def account() -> str:
    return (os.environ.get("ASEMAN_ENGINE_ACCOUNT") or "").strip()


def mode() -> str:
    """``room`` (agent turn) or ``personal`` (Aseman self-chat / Talk)."""
    return (os.environ.get("ASEMAN_ENGINE_MODE") or "room").strip().lower() or "room"


def space_tool_defs() -> list[dict[str, Any]]:
    """MCP tool descriptors shared by room and personal OpenCode runs."""
    obj = {"type": "object"}
    tools = [
        {"name": "send_message", "description": (
            "Post a message in this room while you work. Use for progress and talking "
            "to people or agents. Your final answer to the triggering message is still "
            "your run's reply, not send_message."
        ), "inputSchema": {**obj, "properties": {
            "body": {"type": "string"},
            "mention": {"type": "array", "items": {"type": "string"},
                        "description": "names or account ids to mention"},
            "reply_to": {"type": "string", "description": "message id this answers"},
            "space": {"type": "string", "description": "optional space id (defaults to this turn)"},
            "room": {"type": "string", "description": "optional room id (defaults to this turn)"},
        }, "required": ["body"]}},
        {"name": "read_room", "description": "Read the latest messages of this room (oldest first).",
         "inputSchema": {**obj, "properties": {
             "limit": {"type": "integer"},
             "reply_to": {"type": "string"},
             "space": {"type": "string"},
             "room": {"type": "string"},
         }}},
        {"name": "list_team", "description": "People, agents and apps of this space, with ids.",
         "inputSchema": {**obj, "properties": {"space": {"type": "string"}}}},
        {"name": "send_direct_message", "description": (
            "Send a private direct message to a person or agent (account id or handle)."
        ), "inputSchema": {**obj, "properties": {
            "to": {"type": "string"}, "body": {"type": "string"},
        }, "required": ["to", "body"]}},
        {"name": "read_direct_messages", "description": (
            "Read your direct conversation with a person or agent."
        ), "inputSchema": {**obj, "properties": {
            "peer": {"type": "string"}, "limit": {"type": "integer"},
        }, "required": ["peer"]}},
        {"name": "list_space_tools", "description": (
            "List this space's sandbox, platform tools and connected apps "
            "(from spaces.tools_list). Use call_space_tool to invoke one."
        ), "inputSchema": {**obj, "properties": {"space": {"type": "string"}}}},
        {"name": "call_space_tool", "description": (
            "Call one space tool or connected app through spaces.ask "
            "(same path Deep Agents uses). Pass tool name and args from list_space_tools; "
            "for an app bot, pass bot and body instead."
        ), "inputSchema": {**obj, "properties": {
            "tool": {"type": "string", "description": "platform tool name (e.g. sandbox_exec)"},
            "args": {"type": "object"},
            "bot": {"type": "string", "description": "app bot id when calling a connected app"},
            "body": {"type": "object", "description": "body for a bot ask"},
            "space": {"type": "string"},
            "room": {"type": "string"},
        }}},
        {"name": "recruit_agent", "description": (
            "Create a specialist agent and add it to this space."
        ), "inputSchema": {**obj, "properties": {
            "name": {"type": "string"},
            "description": {"type": "string"},
            "instructions": {"type": "string"},
            "space": {"type": "string"},
            "room": {"type": "string"},
        }, "required": ["name", "instructions"]}},
        {"name": "list_marketplace", "description": (
            "Browse marketplace agents and apps (market.catalog)."
        ), "inputSchema": {**obj, "properties": {
            "status": {"type": "string"},
        }}},
        {"name": "hire_agent", "description": (
            "Hire a marketplace agent listing into this space."
        ), "inputSchema": {**obj, "properties": {
            "listing": {"type": "string"},
            "space": {"type": "string"},
            "room": {"type": "string"},
        }, "required": ["listing"]}},
    ]
    if mode() == "personal":
        tools.extend(_personal_tool_defs(obj))
    return tools


def _personal_tool_defs(obj: dict[str, Any]) -> list[dict[str, Any]]:
    """Account-wide tools for personal Aseman (anything the person can do via actions)."""
    return [
        {"name": "list_rooms", "description": "List the person's project spaces.",
         "inputSchema": {**obj, "properties": {"query": {"type": "string"}}}},
        {"name": "list_chats", "description": "List messenger chats (Aseman personal chat, directs, rooms).",
         "inputSchema": {**obj, "properties": {
             "kind": {"type": "string", "description": "direct, room, or empty"},
             "query": {"type": "string"},
         }}},
        {"name": "create_room", "description": "Create a new project space for the person.",
         "inputSchema": {**obj, "properties": {
             "name": {"type": "string"}, "description": {"type": "string"},
         }, "required": ["name"]}},
        {"name": "space_get", "description": "Get a space (or rich space_detail / space_profile).",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"},
             "detail": {"type": "boolean", "description": "true → spaces.space_detail"},
             "profile": {"type": "boolean", "description": "true → spaces.space_profile"},
         }, "required": ["space"]}},
        {"name": "space_update", "description": "Rename or redescribe a space the person manages.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "name": {"type": "string"}, "description": {"type": "string"},
         }, "required": ["space"]}},
        {"name": "room_create", "description": "Create a room (channel) inside a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "name": {"type": "string"}, "topic": {"type": "string"},
         }, "required": ["space", "name"]}},
        {"name": "room_list", "description": "List rooms of a space.",
         "inputSchema": {**obj, "properties": {"space": {"type": "string"}}, "required": ["space"]}},
        {"name": "room_update", "description": "Rename a room or change its topic/purpose.",
         "inputSchema": {**obj, "properties": {
             "room": {"type": "string"}, "name": {"type": "string"},
             "topic": {"type": "string"}, "purpose": {"type": "string"},
         }, "required": ["room"]}},
        {"name": "thread_list", "description": "List conversation threads in a room.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "room": {"type": "string"},
         }, "required": ["space", "room"]}},
        {"name": "thread_create", "description": "Open a new thread in a room.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "room": {"type": "string"}, "name": {"type": "string"},
         }, "required": ["space", "room"]}},
        {"name": "thread_rename", "description": "Rename a thread.",
         "inputSchema": {**obj, "properties": {
             "thread": {"type": "string"}, "name": {"type": "string"},
         }, "required": ["thread", "name"]}},
        {"name": "thread_delete", "description": "Delete a thread and its messages.",
         "inputSchema": {**obj, "properties": {"thread": {"type": "string"}}, "required": ["thread"]}},
        {"name": "invite_member", "description": "Invite someone to a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "invitee": {"type": "string"}, "role": {"type": "string"},
         }, "required": ["space", "invitee"]}},
        {"name": "remove_member", "description": "Remove a participant from a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "member": {"type": "string"},
         }, "required": ["space", "member"]}},
        {"name": "set_member_role", "description": "Change a participant's role in a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "member": {"type": "string"}, "role": {"type": "string"},
         }, "required": ["space", "member", "role"]}},
        {"name": "list_invitations", "description": "List the person's pending space invitations.",
         "inputSchema": {**obj, "properties": {}}},
        {"name": "accept_invitation", "description": "Accept a space invitation.",
         "inputSchema": {**obj, "properties": {"invitation": {"type": "string"}}, "required": ["invitation"]}},
        {"name": "decline_invitation", "description": "Decline a space invitation.",
         "inputSchema": {**obj, "properties": {"invitation": {"type": "string"}}, "required": ["invitation"]}},
        {"name": "add_bot", "description": "Add an agent/app bot account to a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "bot": {"type": "string"}, "room": {"type": "string"},
         }, "required": ["space", "bot"]}},
        {"name": "remove_bot", "description": "Remove an agent/app from a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "bot": {"type": "string"},
         }, "required": ["space", "bot"]}},
        {"name": "message_edit", "description": "Edit a message the person sent.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "message": {"type": "string"}, "body": {"type": "string"},
         }, "required": ["space", "message", "body"]}},
        {"name": "message_delete", "description": "Delete a message.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "message": {"type": "string"},
         }, "required": ["space", "message"]}},
        {"name": "message_search", "description": "Search messages in a space.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "query": {"type": "string"},
         }, "required": ["space", "query"]}},
        {"name": "file_list", "description": "List files in a space/room.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "room": {"type": "string"},
         }, "required": ["space"]}},
        {"name": "open_direct", "description": "Open (or start) a direct chat with a person or agent.",
         "inputSchema": {**obj, "properties": {"peer": {"type": "string"}}, "required": ["peer"]}},
        {"name": "chat_pin", "description": "Pin or unpin a chat.",
         "inputSchema": {**obj, "properties": {
             "space": {"type": "string"}, "room": {"type": "string"}, "pinned": {"type": "boolean"},
         }, "required": ["space"]}},
        {"name": "explore_spaces", "description": "Search the person's and public spaces (explore).",
         "inputSchema": {**obj, "properties": {"query": {"type": "string"}}, "required": ["query"]}},
        {"name": "post_feed", "description": "Browse the posts feed (global or following).",
         "inputSchema": {**obj, "properties": {
             "following": {"type": "boolean"}, "limit": {"type": "integer"},
         }}},
        {"name": "post_create", "description": "Publish a post (optionally into a workspace).",
         "inputSchema": {**obj, "properties": {
             "body": {"type": "string"}, "space": {"type": "string"},
         }, "required": ["body"]}},
        {"name": "post_like", "description": "Like a post.",
         "inputSchema": {**obj, "properties": {"post": {"type": "string"}}, "required": ["post"]}},
        {"name": "post_comment", "description": "Comment on a post.",
         "inputSchema": {**obj, "properties": {
             "post": {"type": "string"}, "body": {"type": "string"},
         }, "required": ["post", "body"]}},
        {"name": "follow_person", "description": "Follow an account.",
         "inputSchema": {**obj, "properties": {"account": {"type": "string"}}, "required": ["account"]}},
        {"name": "list_following", "description": "List who an account follows.",
         "inputSchema": {**obj, "properties": {"account": {"type": "string"}}}},
        {"name": "install_app", "description": "Install a marketplace listing into a workspace.",
         "inputSchema": {**obj, "properties": {
             "listing": {"type": "string"}, "space": {"type": "string"},
         }, "required": ["listing", "space"]}},
        {"name": "wallet_balance", "description": "The person's credit balance.",
         "inputSchema": {**obj, "properties": {}}},
        {"name": "find_people", "description": "Search people by name, handle or email.",
         "inputSchema": {**obj, "properties": {"query": {"type": "string"}}, "required": ["query"]}},
        {"name": "account_action", "description": (
            "Call any other platform action as the person (namespace + action + body). "
            "Use when no named tool fits: spaces.*, users.*, posts.*, market.*, bots.*, "
            "routines.*, finance.*, … Authorization is still theirs. Never admin/llm-provider."
        ), "inputSchema": {**obj, "properties": {
            "namespace": {"type": "string"},
            "action": {"type": "string"},
            "body": {"type": "object"},
        }, "required": ["namespace", "action"]}},
    ]


def call_space_tool(gateway: Gateway, name: str, args: dict[str, Any]) -> tuple[str, bool]:
    """Run one named space tool. Returns (text, is_error)."""
    try:
        if name == "send_message":
            return _send_message(gateway, args), False
        if name == "read_room":
            return _read_room(gateway, args), False
        if name == "list_team":
            return _list_team(gateway, args), False
        if name == "send_direct_message":
            return _send_dm(gateway, args), False
        if name == "read_direct_messages":
            return _read_dms(gateway, args), False
        if name == "list_space_tools":
            return _list_space_tools(gateway, args), False
        if name == "call_space_tool":
            return _ask_space(gateway, args), False
        if name == "recruit_agent":
            return _recruit(gateway, args), False
        if name == "list_marketplace":
            return _catalog(gateway, args), False
        if name == "hire_agent":
            return _hire(gateway, args), False
        if name in _PERSONAL_HANDLERS:
            return _PERSONAL_HANDLERS[name](gateway, args), False
    except GatewayError as exc:
        return str(exc), True
    return f"unknown space tool {name}", True


def _personal_call(gateway: Gateway, namespace: str, action: str, body: dict[str, Any] | None = None) -> str:
    return _clip(gateway.call_sync(namespace, action, body or {}))


def _list_rooms(gateway: Gateway, args: dict[str, Any]) -> str:
    q = str(args.get("query") or "").strip()
    if q:
        return _personal_call(gateway, "spaces", "space_search", {"query": q})
    return _personal_call(gateway, "spaces", "space_list", {})


def _list_chats(gateway: Gateway, args: dict[str, Any]) -> str:
    body: dict[str, Any] = {}
    if str(args.get("kind") or "").strip():
        body["kind"] = str(args["kind"]).strip()
    if str(args.get("query") or "").strip():
        body["query"] = str(args["query"]).strip()
    return _personal_call(gateway, "spaces", "chat_list", body)


def _create_room(gateway: Gateway, args: dict[str, Any]) -> str:
    return _personal_call(gateway, "spaces", "space_create", {
        "name": str(args.get("name") or "").strip(),
        "description": str(args.get("description") or "").strip(),
    })


def _space_get(gateway: Gateway, args: dict[str, Any]) -> str:
    space = str(args.get("space") or "").strip()
    if args.get("profile"):
        return _personal_call(gateway, "spaces", "space_profile", {"space": space})
    if args.get("detail"):
        return _personal_call(gateway, "spaces", "space_detail", {"space": space})
    return _personal_call(gateway, "spaces", "space_get", {"space": space})


def _account_action(gateway: Gateway, args: dict[str, Any]) -> str:
    namespace = str(args.get("namespace") or "").strip()
    action = str(args.get("action") or "").strip()
    if not namespace or not action:
        raise GatewayError("account_action needs namespace and action")
    body = args.get("body") if isinstance(args.get("body"), dict) else {}
    return _personal_call(gateway, namespace, action, body)


_PERSONAL_HANDLERS = {
    "list_rooms": _list_rooms,
    "list_chats": _list_chats,
    "create_room": _create_room,
    "space_get": _space_get,
    "space_update": lambda g, a: _personal_call(g, "spaces", "space_update", {
        k: a[k] for k in ("space", "name", "description") if str(a.get(k) or "").strip()
    }),
    "room_create": lambda g, a: _personal_call(g, "spaces", "room_create", {
        "space": a.get("space"), "name": a.get("name"), "topic": a.get("topic") or "",
    }),
    "room_list": lambda g, a: _personal_call(g, "spaces", "room_list", {"space": a.get("space")}),
    "room_update": lambda g, a: _personal_call(g, "spaces", "room_update", {
        k: a[k] for k in ("room", "name", "topic", "purpose") if a.get(k) is not None
    }),
    "thread_list": lambda g, a: _personal_call(g, "spaces", "thread_list", {
        "space": a.get("space"), "room": a.get("room"),
    }),
    "thread_create": lambda g, a: _personal_call(g, "spaces", "thread_create", {
        "space": a.get("space"), "room": a.get("room"), "name": a.get("name") or "",
    }),
    "thread_rename": lambda g, a: _personal_call(g, "spaces", "thread_rename", {
        "thread": a.get("thread"), "name": a.get("name"),
    }),
    "thread_delete": lambda g, a: _personal_call(g, "spaces", "thread_delete", {"thread": a.get("thread")}),
    "invite_member": lambda g, a: _personal_call(g, "spaces", "invite", {
        "space": a.get("space"), "invitee": a.get("invitee"), "role": a.get("role") or "",
    }),
    "remove_member": lambda g, a: _personal_call(g, "spaces", "member_remove", {
        "space": a.get("space"), "member": a.get("member"),
    }),
    "set_member_role": lambda g, a: _personal_call(g, "spaces", "member_role", {
        "space": a.get("space"), "member": a.get("member"), "role": a.get("role"),
    }),
    "list_invitations": lambda g, a: _personal_call(g, "spaces", "invitations_list", {}),
    "accept_invitation": lambda g, a: _personal_call(g, "spaces", "invitation_accept", {
        "invitation": a.get("invitation"),
    }),
    "decline_invitation": lambda g, a: _personal_call(g, "spaces", "invitation_decline", {
        "invitation": a.get("invitation"),
    }),
    "add_bot": lambda g, a: _personal_call(g, "spaces", "bot_add", {
        "space": a.get("space"), "bot": a.get("bot"), "room": a.get("room") or "",
    }),
    "remove_bot": lambda g, a: _personal_call(g, "spaces", "bot_remove", {
        "space": a.get("space"), "bot": a.get("bot"),
    }),
    "message_edit": lambda g, a: _personal_call(g, "spaces", "message_edit", {
        "space": a.get("space"), "message": a.get("message"), "body": a.get("body"),
    }),
    "message_delete": lambda g, a: _personal_call(g, "spaces", "message_delete", {
        "space": a.get("space"), "message": a.get("message"),
    }),
    "message_search": lambda g, a: _personal_call(g, "spaces", "message_search", {
        "space": a.get("space"), "query": a.get("query"),
    }),
    "file_list": lambda g, a: _personal_call(g, "spaces", "file_list", {
        "space": a.get("space"), "room": a.get("room") or "",
    }),
    "open_direct": lambda g, a: _personal_call(g, "spaces", "direct_open", {"peer": a.get("peer")}),
    "chat_pin": lambda g, a: _personal_call(g, "spaces", "chat_pin", {
        "space": a.get("space"), "room": a.get("room") or "",
        "pinned": True if a.get("pinned") is None else bool(a.get("pinned")),
    }),
    "explore_spaces": lambda g, a: _personal_call(g, "spaces", "space_search", {"query": a.get("query")}),
    "post_feed": lambda g, a: _personal_call(g, "posts", "post_feed", {
        "following": bool(a.get("following")), "limit": a.get("limit") or 20,
    }),
    "post_create": lambda g, a: _personal_call(g, "posts", "post_create", {
        "body": a.get("body"), "space": a.get("space") or "",
    }),
    "post_like": lambda g, a: _personal_call(g, "posts", "post_like", {"post": a.get("post")}),
    "post_comment": lambda g, a: _personal_call(g, "posts", "post_comment", {
        "post": a.get("post"), "body": a.get("body"),
    }),
    "follow_person": lambda g, a: _personal_call(g, "users", "follow", {"account": a.get("account")}),
    "list_following": lambda g, a: _personal_call(g, "users", "following_list", {
        "account": a.get("account") or "",
    }),
    "install_app": lambda g, a: _personal_call(g, "market", "install", {
        "listing": a.get("listing"), "space": a.get("space"),
    }),
    "wallet_balance": lambda g, a: _personal_call(g, "finance", "wallet_get", {}),
    "find_people": lambda g, a: _personal_call(g, "users", "search", {
        "query": str(a.get("query") or "").lstrip("@"), "limit": 5,
    }),
    "account_action": _account_action,
}


def _scope(args: dict[str, Any]) -> tuple[str, str]:
    sp = str(args.get("space") or "").strip() or space()
    rm = str(args.get("room") or "").strip() or room()
    if not sp:
        raise GatewayError("no space on this turn: pass space=…")
    return sp, rm


def _send_message(gateway: Gateway, args: dict[str, Any]) -> str:
    sp, rm = _scope(args)
    body = str(args.get("body") or "").strip()
    if not body:
        raise GatewayError("send_message needs a body")
    payload: dict[str, Any] = {"space": sp, "body": body}
    if rm:
        payload["room"] = rm
    mentions = args.get("mention") or []
    if isinstance(mentions, list) and mentions:
        payload["mentions"] = [str(m) for m in mentions]
    if str(args.get("reply_to") or "").strip():
        payload["reply_to"] = str(args["reply_to"]).strip()
    out = gateway.call_sync("spaces", "message_send", payload)
    return f"posted message {out.get('message_id', '')}"


def _read_room(gateway: Gateway, args: dict[str, Any]) -> str:
    sp, rm = _scope(args)
    limit = args.get("limit")
    try:
        n = max(1, min(int(limit or 30), 200))
    except (TypeError, ValueError):
        n = 30
    payload: dict[str, Any] = {"space": sp, "limit": n}
    if rm:
        payload["room"] = rm
    if str(args.get("reply_to") or "").strip():
        payload["reply_to"] = str(args["reply_to"]).strip()
    out = gateway.call_sync("spaces", "message_list", payload)
    messages = list(reversed(out.get("messages") or []))
    return _format_messages(messages) or "(no messages)"


def _list_team(gateway: Gateway, args: dict[str, Any]) -> str:
    sp = str(args.get("space") or "").strip() or space()
    if not sp:
        raise GatewayError("list_team needs a space")
    members = gateway.call_sync("spaces", "members_list", {"space": sp})
    bots = gateway.call_sync("spaces", "bots_list", {"space": sp})
    return _clip({"members": members.get("members") or members, "bots": bots.get("bots") or bots})


def _send_dm(gateway: Gateway, args: dict[str, Any]) -> str:
    to = str(args.get("to") or "").strip()
    body = str(args.get("body") or "").strip()
    if not to or not body:
        raise GatewayError("send_direct_message needs to and body")
    out = gateway.call_sync("users", "dm_send", {"to": to, "body": body})
    return f"sent direct message {out.get('id', '')}"


def _read_dms(gateway: Gateway, args: dict[str, Any]) -> str:
    peer = str(args.get("peer") or "").strip()
    if not peer:
        raise GatewayError("read_direct_messages needs peer")
    try:
        limit = max(1, min(int(args.get("limit") or 30), 200))
    except (TypeError, ValueError):
        limit = 30
    out = gateway.call_sync("users", "dm_list", {"peer": peer, "limit": limit})
    me = account()
    lines = []
    for d in out.get("messages") or []:
        who = "you" if str(d.get("from_id") or d.get("from") or "") == me else peer
        lines.append(f"[{d.get('created_at', '')}] {who}: {_short(str(d.get('body', '')), 2000)}")
    return "\n".join(lines) or "(no direct messages)"


def _list_space_tools(gateway: Gateway, args: dict[str, Any]) -> str:
    sp = str(args.get("space") or "").strip() or space()
    if not sp:
        raise GatewayError("list_space_tools needs a space")
    out = gateway.call_sync("spaces", "tools_list", {"space": sp})
    return _clip(out)


def _ask_space(gateway: Gateway, args: dict[str, Any]) -> str:
    sp, rm = _scope(args)
    payload: dict[str, Any] = {"space": sp}
    if rm:
        payload["room"] = rm
    tool = str(args.get("tool") or "").strip()
    bot = str(args.get("bot") or "").strip()
    if tool:
        payload["tool"] = tool
        payload["args"] = args.get("args") if isinstance(args.get("args"), dict) else {}
    elif bot:
        payload["bot"] = bot
        payload["body"] = args.get("body") if isinstance(args.get("body"), dict) else {}
    else:
        raise GatewayError("call_space_tool needs tool=… or bot=…")
    out = gateway.call_sync("spaces", "ask", payload)
    return _clip(out)


def _recruit(gateway: Gateway, args: dict[str, Any]) -> str:
    sp, rm = _scope(args)
    name = str(args.get("name") or "").strip()
    instructions = str(args.get("instructions") or "").strip()
    if not name or not instructions:
        raise GatewayError("recruit_agent needs name and instructions")
    payload: dict[str, Any] = {
        "space": sp, "name": name, "instructions": instructions,
        "description": str(args.get("description") or "").strip() or instructions,
    }
    if rm:
        payload["room"] = rm
    out = gateway.call_sync("spaces", "agent_recruit", payload)
    return _clip(out)


def _catalog(gateway: Gateway, args: dict[str, Any]) -> str:
    body = {}
    if str(args.get("status") or "").strip():
        body["status"] = str(args["status"]).strip()
    return _clip(gateway.call_sync("market", "catalog", body))


def _hire(gateway: Gateway, args: dict[str, Any]) -> str:
    sp, rm = _scope(args)
    listing = str(args.get("listing") or "").strip()
    if not listing:
        raise GatewayError("hire_agent needs listing")
    payload: dict[str, Any] = {"space": sp, "listing": listing}
    if rm:
        payload["room"] = rm
    return _clip(gateway.call_sync("spaces", "agent_hire", payload))


def _format_messages(messages: list[dict[str, Any]]) -> str:
    lines = []
    for m in messages:
        sender = m.get("sender") or {}
        name = sender.get("display_name") or sender.get("handle") or m.get("sender_id", "?")
        kind = str(m.get("kind") or "")
        tag = "" if kind in ("", "text", "message") else f" [{kind}]"
        reply = f" (reply to {m['reply_to']})" if m.get("reply_to") else ""
        lines.append(
            f"[{m.get('created_at', '')}] {name}{tag}{reply} (message {m.get('id', '')}): "
            f"{_short(str(m.get('body', '')), 2000)}"
        )
    return "\n".join(lines)


def _clip(value: Any) -> str:
    return json.dumps(value, default=str)[:20000]


def _short(text: str, n: int) -> str:
    if len(text) <= n:
        return text
    return text[:n] + "…"
