"""OpenCode as the agentic engine.

Headless ``opencode`` runs the turn. Models come from OpenCode's own gateway
(free models only). This package does not call the platform LLM proxy and
does not drive the programmer OpenCode (``aseman-appui``, ``opencode_run``,
``/etc/opencode``).
"""

from .engine import OpenCodeEngine

__all__ = ["OpenCodeEngine"]
