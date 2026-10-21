"""GEPA over an agent's decision points.

GEPA (gepa-ai/gepa) evolves text components of a system from rollouts that are
scored with textual feedback: a reflection model reads what went wrong and
proposes a better text, and a new text is kept only when it scores better on
the examples. Here the system is the agent, the text is its playbook (the part
of its system prompt it learns), and an example is a decision point of one of
its real turns (record.py).

A rollout replays the point: the agent's own model, with its system prompt and
the candidate playbook, is shown the conversation up to that moment, with the
same tools, and takes its next step. Nothing runs — the step is only judged —
so a real request is never repeated (its messages, files and purchases stay
done once). The step is scored against what is known of that moment:

* at a failure or a repeated call, the same step again scores 0; another step
  is judged on whether it is sound and avoids the known problem;
* at an answer that fell short, an answer is judged on whether it delivers,
  and a step that goes on working is judged as a step;
* at a step that worked, the same kind of step scores 1; another is judged.

The judge is the node's decision model (fast, probabilities), else the agent's
model. Every call goes to the node's learn endpoints with the runtime's own
credential and is billed to the project as its agents' learning.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx
from langchain_core.messages import AIMessage, SystemMessage, convert_to_messages

from ..swarm.llm import parse_json

log = logging.getLogger("aseman.agents.improve")

#: A playbook longer than this is not shown in full (characters).
PLAYBOOK_CHARS = 4_000
#: The decision model's timeout for one judgement (seconds).
JUDGE_TIMEOUT = 15.0

REFLECTION_PROMPT = """\
An AI agent works for people in a shared project space: it takes requests in chat
rooms, works on the project's shared computer, uses the project's tools and hands
work to other agents. Besides its fixed instructions it has a playbook, lessons it
learned from its own work in this space:
```
<curr_param>
```

Below are moments from the agent's real work: what had happened so far, the step it
took next with the playbook above, and feedback on that step (what is known to have
gone wrong at that moment, and an independent judgement of the step):
```
<side_info>
```

Write the agent's new playbook. Keep what still holds, fix what the feedback shows is
missing or wrong, and add the lessons these moments teach: what to check before a
step, which approach works and which fails, how to recover from an error instead of
repeating it, what a finished answer must contain. Write lessons that apply to the
next requests too, not facts about one request. Be short and concrete: a list of at
most 15 rules, under 3,000 characters.

Provide the new playbook within ``` blocks."""


def render(playbook: str) -> str:
    """The playbook as it goes into the agent's system prompt."""
    text = (playbook or "").strip()
    if not text:
        return ""
    if len(text) > PLAYBOOK_CHARS:
        text = text[:PLAYBOOK_CHARS].rsplit("\n", 1)[0]
    return ("## Your playbook\nLessons from your own earlier work in this space, refined as you work. Follow "
            "them unless the person or the evidence says otherwise.\n\n" + text)


def describe(action: dict[str, Any]) -> str:
    if "name" in action:
        return f"call `{action['name']}` with {json.dumps(action.get('args') or {}, ensure_ascii=False)[:600]}"
    return f"answer: {str(action.get('text', ''))[:800]}"


def step_of(message: Any) -> dict[str, Any]:
    """The step a replayed model took: its first tool call, else its answer."""
    if isinstance(message, AIMessage) and message.tool_calls:
        call = message.tool_calls[0]
        return {"name": call.get("name", ""), "args": call.get("args") or {}}
    text = message.text if isinstance(getattr(message, "text", None), str) else str(getattr(message, "content", ""))
    return {"text": text}


def same(a: dict[str, Any], b: dict[str, Any]) -> bool:
    if "name" in a and "name" in b:
        return a["name"] == b["name"] and json.dumps(a.get("args") or {}, sort_keys=True, default=str) == \
            json.dumps(b.get("args") or {}, sort_keys=True, default=str)
    return False


class Learn:
    """The node's learn endpoints for one agent in one space (sync: GEPA runs in a thread)."""

    def __init__(self, node_url: str, secret: str, space: str, agent_vm: str, model: str = "", *,
                 transport: httpx.BaseTransport | None = None) -> None:
        self.base = node_url.rstrip("/") + "/deepagents/v1/learn"
        self.headers = {"X-Aseman-Runtime": secret, "X-Aseman-Space": space, "X-Aseman-Agent": agent_vm}
        self.model = model or "default"
        self.transport = transport
        self.http = httpx.Client(headers=self.headers, timeout=httpx.Timeout(connect=10.0, read=600.0, write=60.0,
                                                                            pool=30.0), transport=transport)
        self.decision_on = True

    def chat(self) -> Any:
        """The agent's own model, billed as the project's learning."""
        from langchain_openai import ChatOpenAI

        return ChatOpenAI(model=self.model, base_url=self.base, api_key="aseman-learn", default_headers=self.headers,
                          http_client=httpx.Client(timeout=600.0, transport=self.transport), max_retries=1,
                          use_responses_api=False)

    def decide(self, state: dict[str, Any], questions: dict[str, Any]) -> dict[str, Any] | None:
        """The decision model's answers, or None (it is off, or failed)."""
        if not self.decision_on:
            return None
        try:
            resp = self.http.post(self.base + "/decision/evaluate", json={"state": state, "questions": questions},
                                  timeout=JUDGE_TIMEOUT)
        except httpx.HTTPError as exc:
            log.warning("learning decision failed: %s", exc)
            return None
        if resp.status_code == 409:
            self.decision_on = False  # off: the agent's model judges for the rest of the cycle
            return None
        if resp.status_code >= 300:
            log.warning("learning decision failed: %s %s", resp.status_code, resp.text[:200])
            return None
        answers = resp.json().get("answers")
        return answers if isinstance(answers, dict) else None

    def close(self) -> None:
        self.http.close()


class Judge:
    """Whether a step is sound: the decision model, else the agent's model."""

    def __init__(self, learn: Learn, model: Any) -> None:
        self.learn = learn
        self.model = model

    def sound(self, point: dict[str, Any], step: dict[str, Any]) -> float:
        recent = [{"role": m.get("role"), "content": str(m.get("content") or "")[:500],
                   "calls": [c["function"]["name"] for c in m.get("tool_calls") or []]}
                  for m in point["history"][-6:]]
        answering = "text" in step and point["kind"] == "incomplete"
        state = {"request": point["request"][-2000:], "recent_steps": recent, "known_problem": point["feedback"][:1200],
                 "next_step": describe(step)}
        question = ("Does `next_step`, the agent's answer, deliver what `request` asked for (not promising work, not "
                    "leaving part of it out)?" if answering else
                    "Is `next_step` a sound next step toward what `request` asks, one that does not run into "
                    "`known_problem` again?")
        answers = self.learn.decide(state, {"sound": {
            "type": "boolean", "instructions": question,
            "criteria": {"true": "a competent professional would take this step here",
                         "false": "it repeats what failed, ignores the problem, or does not move the work forward"}}})
        p = ((answers or {}).get("sound") or {}).get("probability")
        if isinstance(p, (int, float)):
            return float(p)
        return self._ask_model(state, question)

    def _ask_model(self, state: dict[str, Any], question: str) -> float:
        prompt = (f"{question}\n\nThe state, as JSON:\n{json.dumps(state, ensure_ascii=False)}\n\n"
                  'Answer only with JSON: {"probability": <0 to 1>, "why": "<one sentence>"}')
        try:
            out = parse_json(str(self.model.invoke(prompt).content))
        except Exception as exc:  # noqa: BLE001 - an unjudged step scores as unknown
            log.warning("learning judgement failed: %s", exc)
            return 0.5
        p = out.get("probability") if isinstance(out, dict) else None
        return max(0.0, min(1.0, float(p))) if isinstance(p, (int, float)) else 0.5


def rollout_fn(model: Any, system: str, tools: dict[str, dict[str, Any]]) -> Any:
    """GEPA's rollout: the agent's next step at a decision point, with a candidate playbook."""

    def rollout(candidate: dict[str, str], point: dict[str, Any]) -> dict[str, Any]:
        playbook = render(candidate.get("playbook", ""))
        messages = [SystemMessage(content=system + ("\n\n" + playbook if playbook else "")),
                    *convert_to_messages(point["history"])]
        available = [tools[n] for n in point.get("tools") or [] if n in tools]
        bound = model.bind_tools(available) if available else model
        answer = bound.invoke(messages)
        return {"messages": [*messages, answer]}

    return rollout


def eval_fn(judge: Judge) -> Any:
    """GEPA's metric and feedback for a replayed step (see the module docstring)."""

    def evaluate(point: dict[str, Any], state: dict[str, Any]) -> tuple[float, str]:
        if state.get("error") is not None:
            return 0.0, f"The step could not be taken: {state['error']}"
        step = step_of(state["messages"][-1])
        before = point["action"]
        if point["kind"] in ("failure", "repeat") and same(step, before):
            return 0.0, f"{point['feedback']} With this playbook the agent took the very same step again."
        if point["kind"] == "good" and "name" in step and step.get("name") == before.get("name"):
            return 1.0, f"{point['feedback']} With this playbook the agent took the same kind of step: good."
        score = judge.sound(point, step)
        verdict = "a sound step" if score >= 0.5 else "not a sound step"
        return score, (f"Known about this moment: {point['feedback']} With this playbook the agent's next step was to "
                       f"{describe(step)}. An independent judge rates it {score:.2f}: {verdict}.")

    return evaluate


def reflective_record(point: dict[str, Any], state: dict[str, Any], score: float, feedback: str) -> dict[str, Any]:
    """What the reflection model reads of one replayed moment."""
    steps = [f"{m.get('role')}: " + (str(m.get("content") or "")[:300] or ", ".join(
        f"called {c['function']['name']}" for c in m.get("tool_calls") or []))
             for m in point["history"][-6:]]
    step = step_of(state["messages"][-1]) if state.get("messages") else {"text": "(no step)"}
    return {"Request": point["request"][:1500], "What had happened": "\n".join(steps),
            "The agent's next step": describe(step), "Score": round(score, 2), "Feedback": feedback}


class _Log:
    """GEPA's progress, in the runtime's log."""

    def log(self, message: str) -> None:
        log.debug("gepa: %s", message)


def optimize(points: list[dict[str, Any]], *, playbook: str, system: str, tools: dict[str, dict[str, Any]],
             learn: Learn, budget: int) -> tuple[str, float, float]:
    """One GEPA run over the decision points: (best playbook, its score, the current one's score)."""
    import gepa
    from gepa.adapters.langchain_adapter import LangChainAdapter, make_reflection_lm

    model = learn.chat()
    adapter = LangChainAdapter(rollout_fn=rollout_fn(model, system, tools), eval_fn=eval_fn(Judge(learn, model)),
                               num_threads=4, reflective_record_fn=reflective_record, show_progress=False)
    result = gepa.optimize(
        seed_candidate={"playbook": playbook}, trainset=points, valset=points, adapter=adapter,
        reflection_lm=make_reflection_lm(model), reflection_prompt_template=REFLECTION_PROMPT,
        max_metric_calls=budget, reflection_minibatch_size=min(3, len(points)), raise_on_exception=False,
        logger=_Log(), display_progress_bar=False, seed=0)
    best = result.best_idx
    return (result.candidates[best]["playbook"], float(result.val_aggregate_scores[best]),
            float(result.val_aggregate_scores[0]))
