"""The swarm: a lead sets up a hybrid team and runs plans with it in parallel.

* team_setup.py — staffing a goal from the space's agents, the marketplace's
  (hired) and new specialists (generated), with the language model and the
  decision model together;
* planner.py — the goal as a plan of tasks with dependencies, the ones that
  are not needed dropped by the decision model;
* executor.py — the LangGraph flow that runs a plan, every task as soon as it
  can start, many at once, each task in its agent's own turn;
* tools.py — ``assemble_team`` and ``run_swarm``, the lead's tools.
"""

from .tools import swarm_tools

__all__ = ["swarm_tools"]
