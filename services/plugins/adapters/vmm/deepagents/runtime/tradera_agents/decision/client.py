"""The turn's client of the node's decision model.

It never fails a turn: a decision that cannot be made is None, and the caller
goes on as if there were no decision model. The node saying the model is off
(409), or a second failure in a turn, turns the client off for the rest of the
turn, so a slow or broken provider costs a turn at most two calls.
"""

from __future__ import annotations

import logging
from typing import Any

from ..gateway import DecisionDisabled, Gateway

log = logging.getLogger("tradera.agents.decision")

#: Failed decisions after which the turn stops asking.
MAX_FAILURES = 2


class DecisionClient:
    def __init__(self, gateway: Gateway, model: str = "") -> None:
        self.gateway = gateway
        self.model = model
        self.enabled = True
        self.calls = 0
        self.failures = 0
        self.input_tokens = 0

    async def evaluate(self, state: Any, questions: dict[str, Any]) -> dict[str, Any] | None:
        """The answers to typed questions about a state, or None."""
        if not self.enabled or not questions:
            return None
        self.calls += 1
        try:
            out = await self.gateway.decide(state, questions)
        except DecisionDisabled:
            self.enabled = False
            return None
        except Exception as exc:  # noqa: BLE001 - a decision never fails the turn
            self.failures += 1
            if self.failures >= MAX_FAILURES:
                self.enabled = False
            log.warning("decision failed (%s): %s", self.model, exc)
            return None
        self.input_tokens += int((out.get("usage") or {}).get("inputTokens") or 0)
        answers = out.get("answers")
        return answers if isinstance(answers, dict) else None


def probability(answers: dict[str, Any] | None, key: str) -> float | None:
    """A boolean answer's probability of yes."""
    value = ((answers or {}).get(key) or {}).get("probability")
    return float(value) if isinstance(value, (int, float)) else None


def choice(answers: dict[str, Any] | None, key: str) -> tuple[str, float] | None:
    """A choice answer: the option picked and its probability."""
    answer = (answers or {}).get(key) or {}
    picked = answer.get("choice")
    if not isinstance(picked, str):
        return None
    p = (answer.get("probabilities") or {}).get(picked)
    return picked, float(p) if isinstance(p, (int, float)) else 0.0


def rungs(answers: dict[str, Any] | None, key: str) -> dict[int, float]:
    """A score answer's probability of each rung (lowest first)."""
    out: dict[int, float] = {}
    for k, v in (((answers or {}).get(key) or {}).get("probabilities") or {}).items():
        try:
            out[int(k)] = float(v)
        except (TypeError, ValueError):
            continue
    return out
