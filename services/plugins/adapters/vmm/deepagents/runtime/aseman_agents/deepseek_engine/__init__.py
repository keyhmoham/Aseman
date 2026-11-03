"""DeepSeek Harness (dsh) as the agentic engine.

Headless ``dsh`` runs the turn with Aseman's plugins mounted by a per-turn
profile patch: the platform LLM route (or the engine's own DeepSeek key),
the agent's OpenViking memory, and the ``aseman`` MCP bridge (space tools,
timeline, Code Mode, questions, hand-offs, swarm, app/plugin creation).
"""

from .engine import DeepSeekEngine

__all__ = ["DeepSeekEngine"]
