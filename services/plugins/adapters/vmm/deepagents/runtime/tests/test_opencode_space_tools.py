"""OpenCode MCP space tools mirror Deep Agents' room tool surface."""

from __future__ import annotations

import json
import os

import pytest

from aseman_agents.opencode_engine import mcp_server
from aseman_agents.opencode_engine import space_tools


class FakeGateway:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict]] = []

    def call_sync(self, namespace: str, action: str, body=None):
        body = body or {}
        self.calls.append((namespace, action, body))
        if action == "message_send":
            return {"message_id": "m1"}
        if action == "message_list":
            return {"messages": [
                {"id": "m0", "body": "hi", "sender": {"display_name": "Ada"}, "created_at": "t0"},
            ]}
        if action == "members_list":
            return {"members": [{"id": "u1"}]}
        if action == "bots_list":
            return {"bots": [{"name": "lead"}]}
        if action == "tools_list":
            return {"tools": [{"name": "sandbox_exec", "bot_id": "sbx"}]}
        if action == "ask":
            return {"reply": "ran"}
        if action == "agent_recruit":
            return {"name": "analyst", "bot_id": "b1", "account_id": "a1"}
        if action == "catalog":
            return {"items": [{"name": "Writer"}]}
        if action == "agent_hire":
            return {"name": "Writer", "bot_id": "b2"}
        if action == "space_list":
            return {"spaces": [{"name": "Home"}]}
        if action == "chat_list":
            return {"chats": [{"saved": True}]}
        if action == "space_create":
            return {"space_id": "s1", "name": body.get("name")}
        return {}


def test_space_tool_defs_include_deepagents_surface() -> None:
    names = {t["name"] for t in space_tools.space_tool_defs()}
    for need in (
        "send_message", "read_room", "list_team", "list_space_tools", "call_space_tool",
        "recruit_agent", "hire_agent", "list_marketplace",
    ):
        assert need in names


def test_mcp_tools_list_prefers_named_space_tools(monkeypatch) -> None:
    monkeypatch.setenv("ASEMAN_ENGINE_MODE", "room")
    names = [t["name"] for t in mcp_server._tools()]
    assert names[0] == "send_message"
    assert "platform_call" in names
    assert names.index("send_message") < names.index("platform_call")


def test_send_message_and_call_space_tool_hit_gateway(monkeypatch) -> None:
    monkeypatch.setenv("ASEMAN_ENGINE_SPACE", "space-1")
    monkeypatch.setenv("ASEMAN_ENGINE_ROOM", "room-1")
    gw = FakeGateway()
    text, err = space_tools.call_space_tool(gw, "send_message", {"body": "working"})
    assert not err and "m1" in text
    assert gw.calls[0][:2] == ("spaces", "message_send")
    assert gw.calls[0][2]["space"] == "space-1"
    text, err = space_tools.call_space_tool(gw, "call_space_tool", {
        "tool": "sandbox_exec", "args": {"command": "ls"},
    })
    assert not err and "ran" in text
    assert ("spaces", "ask") in [(n, a) for n, a, _ in gw.calls]


def test_personal_mode_covers_account_surfaces(monkeypatch) -> None:
    monkeypatch.setenv("ASEMAN_ENGINE_MODE", "personal")
    names = {t["name"] for t in space_tools.space_tool_defs()}
    for need in (
        "list_rooms", "list_chats", "create_room", "room_create", "thread_list",
        "thread_create", "invite_member", "remove_member", "explore_spaces",
        "post_feed", "post_create", "follow_person", "install_app", "account_action",
        "message_search", "open_direct", "wallet_balance",
    ):
        assert need in names, need
    gw = FakeGateway()
    text, err = space_tools.call_space_tool(gw, "list_rooms", {})
    assert not err
    assert json.loads(text)["spaces"][0]["name"] == "Home"
    text, err = space_tools.call_space_tool(gw, "account_action", {
        "namespace": "spaces", "action": "thread_list",
        "body": {"space": "s1", "room": "r1"},
    })
    assert not err
    assert ("spaces", "thread_list") in [(n, a) for n, a, _ in gw.calls]
