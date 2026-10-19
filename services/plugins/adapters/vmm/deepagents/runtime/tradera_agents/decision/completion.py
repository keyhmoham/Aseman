"""Completion: whether the final answer delivers what was asked.

A model sometimes ends its turn on a promise ("I will now…") or with part of
the work. When the agent writes its final answer, the decision model is asked
whether it delivers the request; a confident no sends the agent back to work
once, with steps left in its budget. The agent may still answer the same way:
the check never loops.
"""

from __future__ import annotations

from .client import DecisionClient, probability

#: Below this probability that the answer is complete the agent goes on.
INCOMPLETE_BELOW = 0.25

NOTE = ("An independent check finds your answer does not yet deliver what was asked (it may promise work "
        "that was not done, or leave part of the request out). If there is work left that you can do, do it "
        "now and then answer. If the answer is complete, or what is missing cannot be done, give your final "
        "answer again and say plainly what is missing and why.")


async def incomplete(client: DecisionClient, request: str, answer: str, delivered: list[str] | None = None) -> bool:
    """True when the decision model is confident the answer falls short.

    ``delivered`` are the files and images the agent already sent to the chat in
    this turn (what its delivery tools reported). They are part of the answer:
    without them a request for an image looks unanswered when the image was
    posted and the agent's text only describes it, and the agent was sent back
    to make (and bill) a second one.
    """
    if not request.strip() or not answer.strip():
        return False
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
    p = probability(answers, "complete")
    return p is not None and p < INCOMPLETE_BELOW
