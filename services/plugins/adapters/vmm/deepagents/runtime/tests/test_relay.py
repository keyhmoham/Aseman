"""The relay between OpenCode and the model: tool names, OpenCode's prompt
around the agent's, streams put back together."""

from __future__ import annotations

from tradera_agents.opencode import convert
from tradera_agents.opencode.relay import Assembled
from tradera_agents.opencode.runs import key_token, schema_of
from tradera_agents.opencode.workspace import Projects, project_key
from tradera_agents.context import AgentDef


def test_the_model_sees_the_agents_tool_names_and_opencode_gets_its_own() -> None:
    body = {"tools": [{"type": "function", "function": {"name": "tradera_execute"}},
                      {"type": "function", "function": {"name": "task"}},
                      {"type": "function", "function": {"name": "skill"}}],
            "messages": [{"role": "assistant", "tool_calls": [{"id": "1", "function": {"name": "tradera_read_file"}}]}],
            "tool_choice": {"type": "function", "function": {"name": "tradera_execute"}}}
    convert.model_request(body)
    assert [t["function"]["name"] for t in body["tools"]] == ["execute", "subagent", "skill"]
    assert body["messages"][0]["tool_calls"][0]["function"]["name"] == "read_file"
    assert body["tool_choice"]["function"]["name"] == "execute"
    answer = {"tool_calls": [{"function": {"name": "execute"}}, {"function": {"name": "subagent"}},
                             {"function": {"name": "skill"}}]}
    convert.opencode_message(answer)
    assert [c["function"]["name"] for c in answer["tool_calls"]] == ["tradera_execute", "task", "skill"]


def test_a_streamed_answer_is_put_back_together_with_opencodes_names() -> None:
    a = Assembled()
    first = {"content": "Let me ", "tool_calls": [{"index": 0, "id": "c1", "function": {"name": "exe", "arguments": ""}}]}
    second = {"content": "look.", "tool_calls": [{"index": 0, "function": {"name": "cute", "arguments": '{"command":'}}]}
    third = {"tool_calls": [{"index": 0, "function": {"arguments": '"ls"}'}}]}
    for delta in (first, second, third):
        a.delta(delta)
    # Only the name's first piece carries the prefix: OpenCode joins them.
    assert first["tool_calls"][0]["function"]["name"] + second["tool_calls"][0]["function"]["name"] == "tradera_execute"
    message = a.message()
    assert message["content"] == "Let me look."
    assert message["tool_calls"][0]["function"] == {"name": "execute", "arguments": '{"command":"ls"}'}
    plain = Assembled(translate=False)
    delta = {"tool_calls": [{"index": 0, "function": {"name": "write"}}]}
    plain.delta(delta)
    assert delta["tool_calls"][0]["function"]["name"] == "write"


def test_opencodes_description_of_its_directory_is_dropped() -> None:
    text = ("You read changelogs.\nYou are powered by the model named agent. The exact model ID is tradera/agent\n"
            "Here is some useful information about the environment you are running in:\n<env>\n  Working directory: "
            "/data/x\n</env>\nPER-PROMPT")
    assert convert.strip_env(text) == "You read changelogs.\nPER-PROMPT"


def test_each_project_has_its_own_credential_and_config(tmp_path) -> None:
    key = project_key("vm:space:room")
    assert key != project_key("vm:space:room:task:abc") and len(key) == 24
    assert key_token("s", key) != key_token("s", project_key("other")) != key_token("t", key)
    projects = Projects(tmp_path, "http://127.0.0.1:8000", lambda k: key_token("s", k))
    agent = AgentDef(name="coder", bot_id="b", account_id="a", vm_id="v", model="gpt-x", context_window=200_000,
                     max_tokens=4096)
    config = projects.config(key, agent, steps=40)
    provider = config["provider"]["tradera"]
    assert config["enabled_providers"] == ["tradera"] and config["model"] == "tradera/agent"
    assert provider["options"]["baseURL"] == f"http://127.0.0.1:8000/opencode/llm/{key}/v1"
    assert provider["options"]["apiKey"] == key_token("s", key)
    assert provider["models"]["agent"]["limit"] == {"context": 200_000, "output": 4096}
    assert config["mcp"]["tradera"]["url"].endswith(f"/opencode/mcp/{key}")
    permission = config["agent"]["tradera"]["permission"]
    assert permission["*"] == "deny" and permission["tradera_*"] == "allow" and "task" not in permission
    assert config["agent"]["tradera"]["steps"] == 40
    _, changed = projects.ensure(key, agent, steps=40)
    assert not changed
    _, changed = projects.ensure(key, agent, steps=40)
    assert not changed
    agent.context_window = 100_000
    _, changed = projects.ensure(key, agent, steps=40)
    assert changed


def test_tool_schemas_leave_injected_arguments_out() -> None:
    from deepagents.middleware.filesystem import FilesystemMiddleware

    tools = {t.name: t for t in FilesystemMiddleware().tools}
    schema = schema_of(tools["read_file"])
    assert "file_path" in schema["properties"] and "runtime" not in schema["properties"]
