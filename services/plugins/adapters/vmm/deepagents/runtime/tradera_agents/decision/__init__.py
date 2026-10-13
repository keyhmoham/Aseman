"""The decision module: the node's decision model working with the agent's LLM.

A decision model (TypeSafe AI's Jev on Vercel AI Gateway, or any model of the
decision API) answers typed questions about a state — yes/no, a choice, a
score — with probabilities, fast and for a fraction of a chat call. The node
admin picks one (Admin → Decision model) and turns it on or off.

On, it cooperates with the agent's own model; it narrows, ranks and checks,
and the agent's model still reasons, writes tool arguments and answers:

* tool selection (tools.py) — once per turn, the tools the request needs
  are shortlisted, so every model call carries fewer tool schemas;
* routing (routing.py) — which of the space's agents fits a task best;
* progress (progress.py) — whether a long run of steps is getting anywhere;
* completion (completion.py) — whether the final answer delivers the request;
* approvals (approval.py) — when the admin allows it, low-risk calls of
  tools that wait on a person are approved by the decision model.

Off, or whenever a decision fails, the turn runs exactly as without one: the
agent's own model makes every decision (client.py fails open).
"""

from .client import DecisionClient
from .middleware import DecisionMiddleware

__all__ = ["DecisionClient", "DecisionMiddleware"]
