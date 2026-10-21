"""The decision module: the node's decision model working with the agent's model."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.checkpoint.memory import InMemorySaver

from tradera_agents.agent import Runner
from tradera_agents.store import Store
from fakes import CODER, LEAD, Platform, ScriptedModel, call, turn_request

WORKSPACE = Path(os.environ["TRADERA_WORKSPACE"])

APPS = {
    "github": ["create_issue", "list_issues", "comment_issue", "create_pr", "merge_pr", "list_repos", "search_code",
               "get_file", "list_branches", "close_issue"],
    "gmail": ["send_email", "search_email", "read_email", "list_labels", "draft_email", "reply_email",
              "archive_email", "trash_email", "list_threads", "forward_email"],
    "stripe": ["create_invoice", "list_customers", "refund_charge", "get_balance", "create_customer",
               "list_charges", "create_price", "list_products", "void_invoice", "list_payouts"],
}


def apps() -> list[dict[str, Any]]:
    return [{"name": name, "kind": "tool", "bot_id": f"bot-{name}", "description": f"The {name} app.",
             "commands": [{"name": c, "description": f"{c.replace('_', ' ')} in {name}.",
                           "schema": {"type": "object", "properties": {"body": {"type": "string"}}}}
                          for c in commands]}
            for name, commands in APPS.items()]


class RecordingModel(ScriptedModel):
    """A scripted model that records the tools it is offered on each call."""

    offered: list[list[str]] = []

    def bind_tools(self, tools: Any, **kwargs: Any) -> "RecordingModel":
        self.offered.append([getattr(t, "name", None) or t.get("name") or t["function"]["name"] for t in tools])
        return self


class Jev:
    """A stand-in decision model with settable answers."""

    def __init__(self) -> None:
        self.complete = 0.95
        self.progress = 0.9
        self.route: dict[str, float] = {}
        self.risk: dict[str, list[float]] = {}

    def __call__(self, state: Any, questions: dict[str, Any]) -> dict[str, Any]:
        text = json.dumps(state).lower()
        out: dict[str, Any] = {}
        for key, q in questions.items():
            if q["type"] == "boolean" and key.startswith("t"):
                tool = q["instructions"].split("`")[1]
                app, _, command = tool.partition("__")
                hit = app in text and (not command or command.split("_")[0] in text)
                out[key] = {"type": "boolean", "probability": 0.9 if hit else 0.05}
            elif key == "complete":
                out[key] = {"type": "boolean", "probability": self.complete}
            elif key == "progress":
                out[key] = {"type": "boolean", "probability": self.progress}
            elif q["type"] == "choice":
                probs = {k: self.route.get(k, 0.0) for k in q["criteria"]}
                best = max(probs, key=probs.get)
                out[key] = {"type": "choice", "choice": best, "probabilities": probs}
            elif q["type"] == "score":
                tool = q["instructions"].split("`")[1]
                rungs = self.risk.get(tool, [0.0, 0.0, 1.0])
                out[key] = {"type": "score", "score": 2.0, "probabilities": {str(i): p for i, p in enumerate(rungs)}}
        return out


@pytest.fixture
def platform(tmp_path: Path) -> Platform:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = Platform(str(tmp_path))
    p.tokens = {"tok-lead": LEAD["account_id"], "tok-coder": CODER["account_id"]}
    p.apps = apps()
    return p


def runner(platform: Platform, tmp_path: Path, script: list[Any]) -> tuple[Runner, RecordingModel]:
    model = RecordingModel(script=script)
    model.seen, model.offered = [], []
    r = Runner(Store(str(tmp_path / "rt.db")), InMemorySaver(), model_factory=lambda agent, gw: model,
               gateway_factory=platform.gateway)
    return r, model


def request(message: str, *, decision: bool = True, auto_approve: bool = False, **extra: Any) -> dict[str, Any]:
    req = turn_request(LEAD, message, token="tok-lead", role="lead", message_id="m0", **extra)
    if decision:
        req["decision"] = {"enabled": True, "model": "typesafe-ai/jev", "auto_approve": auto_approve}
    return req


def notes(model: RecordingModel, call: int) -> str:
    return "\n".join(str(m.content) for m in model.seen[call]
                     if isinstance(m, HumanMessage) and str(m.content).startswith("[runtime note]"))


async def test_the_decision_model_never_changes_the_tools(platform: Platform, tmp_path: Path) -> None:
    platform.decide = Jev()
    r, model = runner(platform, tmp_path, [call("github__create_issue", {"body": "x"}), AIMessage(content="ok")])
    out = await r.prompt(request("open a github issue"))
    assert out.status == "done"
    assert not [d for d in platform.decisions if any(k.startswith("t") for k in d["questions"])]
    # Only the agent's own use changes them: the app it called is loaded (apps.py).
    assert set(model.offered[1]) - set(model.offered[0]) == {f"github__{c}" for c in APPS["github"]}


async def test_a_broken_decision_provider_never_fails_a_turn(platform: Platform, tmp_path: Path) -> None:
    platform.decide, platform.decision_status = Jev(), 502
    r, model = runner(platform, tmp_path, [call("github__create_issue", {"body": "x"}), AIMessage(content="ok")])
    out = await r.prompt(request("open a github issue"))
    assert out.status == "done" and out.reply == "ok"
    assert len(platform.decisions) <= 2  # the client stops asking for the turn


async def test_the_agent_decides_when_it_is_done(platform: Platform, tmp_path: Path) -> None:
    jev = Jev()
    jev.complete = jev.progress = 0.05
    platform.decide = jev
    r, model = runner(platform, tmp_path, [AIMessage(content="I will now open the issue.")])
    out = await r.prompt(request("open a github issue"))
    assert out.reply == "I will now open the issue." and len(model.seen) == 1


async def test_low_risk_approvals_run_and_the_rest_wait(platform: Platform, tmp_path: Path) -> None:
    jev = Jev()
    jev.risk = {"file_send": [0.98, 0.02, 0.0], "github__merge_pr": [0.0, 0.1, 0.9]}
    platform.decide = jev
    target = WORKSPACE / "report.txt"
    target.write_text("r")
    both = AIMessage(content="", tool_calls=[
        {"name": "file_send", "args": {"path": str(target)}, "id": "c-send", "type": "tool_call"},
        {"name": "github__merge_pr", "args": {"body": "#7"}, "id": "c-merge", "type": "tool_call"}])
    r, model = runner(platform, tmp_path, [both, AIMessage(content="Sent and merged.")])
    out = await r.prompt(request("send the report and merge the github pr", auto_approve=True,
                                 interrupt_on=["file_send", "github__merge_pr"]))
    assert out.status == "awaiting"
    assert "github__merge_pr" in out.reply and "file_send" not in out.reply
    # People approve the risky one; the turn resumes with the same calls waiting.
    resumed = await r.answer({**request("yes", auto_approve=True, interrupt_on=["file_send", "github__merge_pr"])})
    assert resumed.answered and resumed.status == "done", resumed
    runs = {t.get("tool") or t.get("bot") for t in platform.tool_runs}
    assert {"file_send", "bot-github"} <= runs
    assert any("auto-approved as low risk: file_send" in (log.get("text") or "") for log in platform.logs)


async def test_a_paused_turn_resumes_after_the_admin_turns_decisions_off(platform: Platform, tmp_path: Path) -> None:
    jev = Jev()
    jev.risk = {"file_send": [0.99, 0.01, 0.0], "github__merge_pr": [0.0, 0.0, 1.0]}
    platform.decide = jev
    target = WORKSPACE / "r2.txt"
    target.write_text("r")
    both = AIMessage(content="", tool_calls=[
        {"name": "file_send", "args": {"path": str(target)}, "id": "d-send", "type": "tool_call"},
        {"name": "github__merge_pr", "args": {"body": "#8"}, "id": "d-merge", "type": "tool_call"}])
    r, _ = runner(platform, tmp_path, [both, AIMessage(content="Done.")])
    tools = ["file_send", "github__merge_pr"]
    out = await r.prompt(request("send the report and merge the github pr", auto_approve=True, interrupt_on=tools))
    assert out.status == "awaiting"
    # The admin turns the decision model off before people answer.
    resumed = await r.answer(request("yes", decision=False, interrupt_on=tools))
    assert resumed.answered and resumed.status == "done", resumed


async def test_without_auto_approve_people_approve_everything(platform: Platform, tmp_path: Path) -> None:
    jev = Jev()
    jev.risk = {"file_send": [1.0, 0.0, 0.0]}
    platform.decide = jev
    r, _ = runner(platform, tmp_path, [call("file_send", {"path": "/workspace/x"}), AIMessage(content="ok")])
    out = await r.prompt(request("send it", interrupt_on=["file_send"]))
    assert out.status == "awaiting" and "file_send" in out.reply
    assert not [d for d in platform.decisions if any(q["type"] == "score" for q in d["questions"].values())]


async def test_routing_resolves_a_hand_off_by_role(platform: Platform, tmp_path: Path) -> None:
    jev = Jev()
    jev.route = {"coder": 0.93}
    platform.decide = jev
    platform.responders[CODER["account_id"]] = lambda body: "done coding"
    r, model = runner(platform, tmp_path, [
        call("run_swarm", {"goal": "fix the login bug",
                           "tasks": [{"id": "t1", "agent": "the developer", "task": "fix the login bug"}]}),
        AIMessage(content="Handed to the coder."),
    ])
    out = await r.prompt(request("get the login bug fixed"))
    assert out.status == "done"
    assert any(CODER["account_id"] in (m.get("mentions") or []) for m in platform.messages)


async def test_a_lead_gets_a_routing_hint(platform: Platform, tmp_path: Path) -> None:
    platform.bots.append({"id": "bot-writer", "account_id": "acc-writer", "name": "writer", "vm_id": "vm-writer",
                          "kind": "agent", "vm_type": "deepagents", "description": "Writes docs and posts."})
    jev = Jev()
    jev.route = {"writer": 0.88, "coder": 0.1}
    platform.decide = jev
    r, model = runner(platform, tmp_path, [AIMessage(content="ok")])
    await r.prompt(request("write a blog post about the launch"))
    assert "writer fits this request best" in notes(model, 0)


async def test_completion_counts_what_was_delivered() -> None:
    from langchain_core.messages import ToolMessage

    from tradera_agents.decision import completion
    from tradera_agents.decision.middleware import delivered

    messages = [
        HumanMessage(content="generate a floating banana image"),
        call("image_generate", {"prompt": "a banana"}, cid="c1"),
        ToolMessage(content="Sent floating_banana.png to the chat (file id f1)", name="image_generate", tool_call_id="c1"),
        call("file_send", {"file_id": "f1"}, cid="c2"),
        ToolMessage(content="error: file_send requires a sandbox path", name="file_send", tool_call_id="c2"),
        AIMessage(content="Here is your floating banana."),
    ]
    sent = delivered(messages)
    assert sent == ["image_generate: Sent floating_banana.png to the chat (file id f1)"]
    # An earlier request's deliveries do not count for this one.
    assert delivered([*messages, HumanMessage(content="now a cat")]) == []

    class Client:
        state: dict[str, Any] = {}

        async def evaluate(self, state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any]:
            Client.state = state
            assert "delivered" in questions["complete"]["instructions"]
            return {"complete": {"type": "boolean", "probability": 0.9}}

    assert await completion.complete(Client(), "generate a floating banana image", "Here is your floating banana.", sent) == 0.9
    assert "floating_banana.png" in Client.state["delivered"]
