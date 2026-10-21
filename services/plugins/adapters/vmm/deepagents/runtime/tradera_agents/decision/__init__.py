"""The decision module: the node's decision model working with the agent's LLM.

A decision model (TypeSafe AI's Jev on Vercel AI Gateway, or any model of the
decision API) answers typed questions about a state — yes/no, a choice, a
score — with probabilities, fast and for a fraction of a chat call. The node
admin picks one (Admin → Decision model) and turns it on or off.

On, it helps the agent's own model in a few narrow places, and the agent's
model still chooses its tools, reasons, writes tool arguments and decides
when it is done:

* routing (routing.py) — which of the space's agents fits a task best;
* approvals (approval.py) — when the admin allows it, low-risk calls of
  tools that wait on a person are approved by the decision model;
* completion (completion.py) — after a turn, how well its answer delivered
  the request, for the agent's learning.

Off, or whenever a decision fails, the turn runs exactly as without one: the
agent's own model makes every decision (client.py fails open).
"""

from .client import DecisionClient
from .middleware import DecisionMiddleware

__all__ = ["DecisionClient", "DecisionMiddleware"]
