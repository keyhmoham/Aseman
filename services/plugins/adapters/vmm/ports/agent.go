package vmm

import "context"

// SandboxRef addresses the shared space sandbox VM an agent engine works in.
type SandboxRef struct {
	Type Type   `json:"type"`
	VMID string `json:"vm_id"`
}

// AgentIdentity is the platform identity of the agent a turn is addressed to.
type AgentIdentity struct {
	BotID     string `json:"bot_id"`
	AccountID string `json:"account_id"`
	Name      string `json:"name"`
}

// AgentTurn is one room message routed to an agent engine. The host resolves
// identities, the space/room context and the sandbox; the engine only decides
// how to run the agent.
type AgentTurn struct {
	Agent   AgentIdentity `json:"agent"`
	SpaceID string        `json:"space_id"`
	RoomID  string        `json:"room_id"`
	// MessageID is the room message that started the turn; the reply is posted
	// as an answer to it (reply_to), which is how a delegating agent finds it.
	MessageID string `json:"message_id,omitempty"`
	// QuestionID names the open question this message answers (Reply only);
	// empty means "the agent's oldest open question in this room".
	QuestionID string `json:"question_id,omitempty"`
	// SenderID / SenderName identify who wrote the message (user or agent).
	SenderID   string `json:"sender_id"`
	SenderName string `json:"sender_name"`
	Message    string `json:"message"`
	// Context is a host-rendered description of the space, room and its
	// members, prepended to triggered turns so the agent knows its scope.
	Context string `json:"context,omitempty"`
	// Note is what is only true for this turn (the sender's local time). It
	// travels with the message, not the system prompt, so the prompt stays the
	// same from turn to turn and the provider's prompt cache keeps matching.
	Note        string           `json:"note,omitempty"`
	Attachments []FileAttachment `json:"attachments,omitempty"`
	// Sandbox is the shared space sandbox the engine runs in.
	Sandbox      SandboxRef `json:"sandbox"`
	NoSandbox    bool       `json:"no_sandbox,omitempty"`
	NoMemory     bool       `json:"no_memory,omitempty"`
	RequestScope string     `json:"request_scope,omitempty"`
}

// AgentRuntime is implemented by agent engines driven through space messaging.
// Prompt runs a turn the agent was triggered by (mention or direct ask) and
// returns its reply. Observe records a room message the agent was not asked to
// answer, so later turns see the conversation it missed. Reply resolves a
// question the agent asked in the room: it reports whether the message was
// consumed as that answer and returns what the agent said after resuming.
type AgentRuntime interface {
	Prompt(ctx context.Context, vmID string, turn AgentTurn) (string, error)
	Observe(ctx context.Context, vmID string, turn AgentTurn) error
	Reply(ctx context.Context, vmID string, turn AgentTurn) (bool, string, error)
}

// AgentQuestion is a question an agent asked people and is waiting on.
type AgentQuestion struct {
	ID       string   `json:"id"`
	BotID    string   `json:"bot_id"`
	Agent    string   `json:"agent"`
	SpaceID  string   `json:"space_id"`
	RoomID   string   `json:"room_id"`
	Question string   `json:"question"`
	Options  []string `json:"options,omitempty"`
	// Kind is "question" (asked with ask_user) or "approval" (a tool call
	// waiting for a person's go-ahead).
	Kind         string `json:"kind"`
	AskedAt      string `json:"asked_at"`
	NoSandbox    bool   `json:"no_sandbox,omitempty"`
	NoMemory     bool   `json:"no_memory,omitempty"`
	RequestScope string `json:"request_scope,omitempty"`
}

// QuestionLister is implemented by agent runtimes that can list the questions
// their agents are waiting on in a space.
type QuestionLister interface {
	Questions(ctx context.Context, vmID, spaceID string) ([]AgentQuestion, error)
}

// RoomForgetter is implemented by agent runtimes that keep each agent's
// conversation per room: ForgetRoom drops every agent's conversation of a
// room (a room thread deleted with its messages).
type RoomForgetter interface {
	ForgetRoom(ctx context.Context, spaceID, roomID string) error
}

// PersonalChat is one answer of the person's own Aseman (the assistant chat
// and Talk) without a room turn: the agent runtime (DeepSeek Harness) runs it
// on the assistant's platform model, as the person, through the person's
// gateway session.
type PersonalChat struct {
	System   string        `json:"system"`
	Messages []ChatMessage `json:"messages"`
	// ThreadID keeps one conversation (dsh Session) across turns for one person.
	ThreadID string `json:"thread_id,omitempty"`
	// PersonID is who the gateway session acts as (required when WithTools).
	PersonID string `json:"person_id,omitempty"`
	// WithTools mints a person-scoped turn gateway and gives the assistant its
	// space tools (same bridge room turns use).
	WithTools bool `json:"with_tools,omitempty"`
	// Provider and Model are the assistant's platform model. An engine on the
	// platform's models (DeepSeek Harness) calls it through the person's
	// gateway session.
	Provider string `json:"provider,omitempty"`
	Model    string `json:"model,omitempty"`
	// Usage, when set, receives the tokens the platform's models used, for
	// the caller to bill.
	Usage *ChatUsage `json:"-"`
}

// ChatUsage is what a personal chat used of the platform's models.
type ChatUsage struct {
	TokensIn  int64
	TokensOut int64
}

// PersonalChatter is implemented by agent runtimes that can answer personal
// Aseman chats under the node's agentic engine setting.
type PersonalChatter interface {
	PersonalChat(ctx context.Context, chat PersonalChat) (string, error)
}

// EngineMemoryView is what an agentic engine that keeps its own memory (DeepSeek
// Harness) holds about a space: its shared notes and, for one agent, that
// agent's notes and latest journal.
type EngineMemoryView struct {
	Engine     string                `json:"engine"`
	SpaceNotes string                `json:"space_notes"`
	Agents     []string              `json:"agents"`
	Agent      string                `json:"agent,omitempty"`
	Notes      string                `json:"notes,omitempty"`
	Journal    []EngineMemoryJournal `json:"journal,omitempty"`
}

// EngineMemoryJournal is one day of an agent's journal.
type EngineMemoryJournal struct {
	Day  string `json:"day"`
	Text string `json:"text"`
}

// EngineMemory is implemented by agent runtimes whose engine keeps its own
// memory, so the platform (the project's Memory screen) reads and corrects
// what that engine's agents really read. agentID is the agent's bot id; empty
// is the space's shared notes.
type EngineMemory interface {
	EngineMemoryRead(ctx context.Context, engine, spaceID, agentID string) (*EngineMemoryView, error)
	EngineMemoryWrite(ctx context.Context, engine, spaceID, agentID, content string) error
}

// MaxAgentAskDepth bounds chains of agents asking agents.
const MaxAgentAskDepth = 4

type agentAskKey struct{}

// WithAgentAsk marks a turn as requested by another agent (agent_ask), one
// level deeper than the current chain.
func WithAgentAsk(ctx context.Context) context.Context {
	return context.WithValue(ctx, agentAskKey{}, AgentAskDepth(ctx)+1)
}

// AgentAskDepth is how many agent-to-agent asks led to this turn (0 when a
// person triggered it). Runtimes avoid waiting on busy agents for such turns,
// so agents asking each other back cannot deadlock.
func AgentAskDepth(ctx context.Context) int {
	d, _ := ctx.Value(agentAskKey{}).(int)
	return d
}

// PersonMemory is implemented by the agent runtime that keeps a person's own
// memory with their Aseman (personal chat): notes always in context and
// long-term memories recalled by meaning. Only the person's own surfaces use
// it; nothing of it reaches any space.
type PersonMemory interface {
	PersonNotes(ctx context.Context, person string) (string, error)
	PersonSetNotes(ctx context.Context, person, content string) error
	PersonRecall(ctx context.Context, person, query string, limit int) ([]string, error)
	// PersonLearn learns from one exchange in the background (best effort).
	PersonLearn(ctx context.Context, person, said, reply string)
}
