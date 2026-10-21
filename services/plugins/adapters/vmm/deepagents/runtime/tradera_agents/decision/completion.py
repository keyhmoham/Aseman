"""Completion: how well a finished turn's answer delivers what was asked.

The agent's learning scores its turns with it after they end (improve/); it
never sends the agent back to work during a turn.
"""

from __future__ import annotations

from .client import DecisionClient, probability


async def complete(client: DecisionClient, request: str, answer: str, delivered: list[str] | None = None) -> float | None:
    """The decision model's probability that the answer delivers the request
    (None when it cannot say).

    ``delivered`` are the files and images the agent already sent to the chat in
    this turn (what its delivery tools reported). They are part of the answer:
    without them a request for an image looks unanswered when the image was
    posted and the agent's text only describes it.
    """
    if not request.strip() or not answer.strip():
        return None
    state: dict[str, str] = {"request": request[-4000:], "answer": answer[:6000]}
    instructions = "Does `answer` deliver what `request` asked for?"
    if delivered:
        state["delivered"] = "\n".join(delivered)[:2000]
        instructions = ("Does `answer`, together with the files and images in `delivered` (already sent to the person "
                        "in the chat), deliver what `request` asked for?")
    answers = await client.evaluate(state, {"complete": {
        "type": "boolean",
        "instructions": instructions,
        "criteria": {"true": "the requested result is given (in the answer or as a delivered file or image), or it is "
                             "clearly explained why it cannot be",
                     "false": "work is only promised, or part of the request is silently left out"}}})
    return probability(answers, "complete")
