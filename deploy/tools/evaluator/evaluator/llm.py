"""Who reads the posts and writes the reliability report.

By default the space's lead agent — the built-in "tradera" agent, a member of
every project — is asked through the tool gateway (spaces.ask) in the admins
space; its model, metering and billing are the platform's own. An admin can
name another agent (`agent_bot`) or point the evaluator at an
OpenAI-compatible endpoint (`llm_base_url`, `llm_api_key`, `llm_model`).
"""

from __future__ import annotations

import json
import urllib.request

from .host import HostError, Node, Scope

SYSTEM = ("You are the Tradera trader evaluator. Follow the evaluation instructions exactly, use only the "
          "data given, and answer with the Final JSON object only.")


def lead_agent(node: Node, scope: Scope) -> str:
    """The bot id of the space's lead agent (handle "tradera")."""
    members = node.call(scope, "spaces", "members_list", {"limit": 200}, timeout=30).get("members") or []
    for m in members:
        if str(m.get("handle") or "").lower() == "tradera" and m.get("bot_id"):
            return m["bot_id"]
    for m in members:
        if m.get("kind") == "bot" and m.get("bot_id") and m.get("bot_id") != scope.tool:
            return m["bot_id"]
    raise HostError("no agent in the admins space to analyse with; set agent_bot or an LLM endpoint with `configure`")


def ask_agent(node: Node, scope: Scope, prompt: str, agent_bot: str = "") -> str:
    bot = agent_bot or lead_agent(node, scope)
    out = node.call(scope, "spaces", "ask", {"bot": bot, "body": prompt}, timeout=1800)
    reply = out.get("reply")
    return reply if isinstance(reply, str) else json.dumps(reply)


def ask_endpoint(base_url: str, api_key: str, model: str, prompt: str, timeout: float = 900.0) -> str:
    body = {"model": model, "temperature": 0,
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]}
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 method="POST", headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(req, timeout=timeout) as res:
        data = json.loads(res.read())
    return data["choices"][0]["message"]["content"]


def analyse(node: Node, space_scope: Scope | None, config: dict, prompt: str) -> tuple[str, str]:
    """(the model's reply, who answered)."""
    if config.get("llm_base_url") and config.get("llm_model"):
        return ask_endpoint(config["llm_base_url"], config.get("llm_api_key") or "", config["llm_model"], prompt), \
            f"endpoint:{config['llm_model']}"
    if space_scope is None:
        raise HostError("no space scope to ask the agent in: the admins space routine has not called `tick` recently")
    return ask_agent(node, space_scope, prompt, config.get("agent_bot") or ""), "agent"
