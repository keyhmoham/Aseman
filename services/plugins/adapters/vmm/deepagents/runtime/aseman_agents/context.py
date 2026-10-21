"""What one turn knows: the agent, where it works and who asked."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .gateway import Gateway


@dataclass
class Skill:
    name: str
    description: str = ""
    instructions: str = ""
    tools: list[str] = field(default_factory=list)


@dataclass
class AgentDef:
    """An agent definition as the node sends it (the adapter's agentPayload)."""

    name: str
    bot_id: str
    account_id: str
    vm_id: str
    description: str = ""
    provider: str = ""
    model: str = ""
    instructions: str = ""
    role: str = ""
    max_tokens: int = 0
    max_turns: int = 0
    allowed_tools: list[str] = field(default_factory=list)
    skills: list[Skill] = field(default_factory=list)
    interrupt_on: list[str] = field(default_factory=list)
    reasoning_effort: str = ""
    context_window: int = 0

    @property
    def lead(self) -> bool:
        return self.role in ("lead", "orchestrator")

    @classmethod
    def from_payload(cls, raw: dict[str, Any]) -> AgentDef:
        skills = [Skill(name=s.get("name", ""), description=s.get("description", ""),
                        instructions=s.get("instructions", ""), tools=list(s.get("tools") or []))
                  for s in raw.get("skills") or [] if s.get("name")]
        return cls(
            name=raw.get("name") or "agent", bot_id=raw.get("bot_id", ""), account_id=raw.get("account_id", ""),
            vm_id=raw.get("vm_id", ""), description=raw.get("description", ""), provider=raw.get("provider", ""),
            model=raw.get("model", ""), instructions=raw.get("instructions", ""), role=raw.get("role", ""),
            max_tokens=int(raw.get("max_tokens") or 0), max_turns=int(raw.get("max_turns") or 0),
            allowed_tools=list(raw.get("allowed_tools") or []), skills=skills,
            interrupt_on=list(raw.get("interrupt_on") or []), reasoning_effort=raw.get("reasoning_effort", ""),
            context_window=int(raw.get("context_window") or 0),
        )


@dataclass
class Turn:
    """One room message routed to the agent (vmm.AgentTurn)."""

    space_id: str
    room_id: str
    message: str
    message_id: str = ""
    question_id: str = ""
    sender_id: str = ""
    sender_name: str = ""
    context: str = ""
    # What is only true for this turn (the person's local time): shown with the message.
    note: str = ""
    attachments: list[dict[str, Any]] = field(default_factory=list)
    sandbox_vm: str = ""
    no_sandbox: bool = False
    no_memory: bool = False
    request_scope: str = ""
    # A parallel instance of the agent: a delegated task it takes while its
    # thread in the room is busy runs on a thread of its own (see team.TASK_TAG).
    instance: str = ""

    @classmethod
    def from_payload(cls, raw: dict[str, Any]) -> Turn:
        return cls(
            space_id=raw.get("space_id", ""), room_id=raw.get("room_id", ""), message=raw.get("message", ""),
            message_id=raw.get("message_id", ""), question_id=raw.get("question_id", ""),
            sender_id=raw.get("sender_id", ""), sender_name=raw.get("sender_name", ""),
            context=raw.get("context", ""), note=raw.get("note", ""), attachments=list(raw.get("attachments") or []),
            sandbox_vm=(raw.get("sandbox") or {}).get("vm_id", ""),
            no_sandbox=bool(raw.get("no_sandbox")), no_memory=bool(raw.get("no_memory")),
            request_scope=raw.get("request_scope", ""),
        )


@dataclass
class DecisionConfig:
    """The node's decision model for the turn (absent: the agent's own model
    makes every decision)."""

    model: str = ""
    auto_approve: bool = False

    @classmethod
    def from_payload(cls, raw: dict[str, Any] | None) -> DecisionConfig | None:
        if not raw or not raw.get("enabled"):
            return None
        return cls(model=str(raw.get("model") or ""), auto_approve=bool(raw.get("auto_approve")))


@dataclass
class TurnContext:
    """Everything a turn's tools need: the gateway and the turn's scope."""

    gateway: Gateway
    agent: AgentDef
    turn: Turn
    # Filled lazily from spaces.tools_list.
    sandbox_bot: str = ""
    tools_cache: list[dict[str, Any]] | None = None
    # The thread's current conversation (see Store.generation).
    generation: int = 0
    # The node's decision model, when the admin turned it on (see decision/).
    decision_config: DecisionConfig | None = None
    # Its client for the turn, set when the turn is built.
    decision: Any = None
    # The agent's memory in OpenViking (memory.Memory); None when the turn has none.
    memory: Any = None
    # Whether the node serves the space's timeline to the turn (timeline.py).
    timeline: bool = False
    # The agent's own chat model for side calls (the swarm's planning and team
    # setup): a LangChain chat model behind the turn's metered LLM endpoint.
    llm: Any = None
    # What the agent's self-improvement keeps of the turn (improve.TurnNotes).
    learning: Any = None

    @property
    def space(self) -> str:
        return self.turn.space_id

    @property
    def room(self) -> str:
        return self.turn.room_id

    @property
    def base_thread(self) -> str:
        """The agent's thread: one per agent per room (or per restricted request)."""
        thread = f"{self.agent.vm_id}:{self.turn.space_id}:{self.turn.room_id}"
        if self.turn.request_scope:
            thread += f":request:{self.turn.request_scope}"
        return f"{thread}:task:{self.turn.instance}" if self.turn.instance else thread

    @property
    def thread_id(self) -> str:
        """The LangGraph thread of the thread's current conversation."""
        return f"{self.base_thread}:gen:{self.generation}" if self.generation else self.base_thread

    async def space_tools(self) -> list[dict[str, Any]]:
        if self.tools_cache is None:
            out = await self.gateway.call("spaces", "tools_list", {"space": self.space})
            self.tools_cache = list(out.get("tools") or [])
            for tool in self.tools_cache:
                if tool.get("name") == "sandbox_exec" and tool.get("bot_id"):
                    self.sandbox_bot = tool["bot_id"]
        return self.tools_cache
