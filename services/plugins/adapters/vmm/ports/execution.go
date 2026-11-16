package vmm

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
)

// Execution is host-issued identity and capability policy, never derived from
// model output, skills, conversation history or tool responses.
type Execution struct {
	ActorID   string
	AgentID   string
	SpaceID   string
	RoomID    string
	RunID     string
	StepID    string
	AttemptID string
	// Request modifiers are host-issued and inherited by every delegated turn.
	NoSandbox    bool
	NoMemory     bool
	RequestScope string
	// Chat marks work that answered a person in a chat (an agent in their
	// notes), which has no room: its charges are their own usage, "Chats".
	Chat bool
	// Nil means the host's workspace policy; a non-nil empty list denies all tools.
	ToolCallID   string
	Capabilities []string
}
type executionKey struct{}

func WithExecution(ctx context.Context, e Execution) context.Context {
	return context.WithValue(ctx, executionKey{}, e)
}
func ExecutionFrom(ctx context.Context) Execution {
	e, _ := ctx.Value(executionKey{}).(Execution)
	return e
}

// A surface sink collects AG-UI cards a turn should show with its answer.
// The reply the person reads is the message both clients draw.
type surfaceKey struct{}

type SurfaceSink struct {
	mu     sync.Mutex
	bodies []string
}

func WithSurfaceSink(ctx context.Context, sink *SurfaceSink) context.Context {
	if sink == nil {
		return ctx
	}
	return context.WithValue(ctx, surfaceKey{}, sink)
}

// NoteSurface records a card to show with the turn's answer. It reports
// whether this turn collects cards instead of posting them as their own message.
func NoteSurface(ctx context.Context, body string) bool {
	sink, _ := ctx.Value(surfaceKey{}).(*SurfaceSink)
	if sink == nil {
		return false
	}
	body = strings.TrimSpace(body)
	if body == "" {
		return true
	}
	sink.mu.Lock()
	sink.bodies = append(sink.bodies, body)
	sink.mu.Unlock()
	return true
}

// JoinSurfaces puts cards in front of the reply, once, so the chart sits
// above the takeaway in the message the person reads.
func JoinSurfaces(reply string, surfaces []string) string {
	var head []string
	seen := reply
	for _, surf := range surfaces {
		surf = strings.TrimSpace(surf)
		if surf == "" || strings.Contains(seen, surf) {
			continue
		}
		head = append(head, surf)
		seen += "\n" + surf
	}
	reply = strings.TrimSpace(reply)
	if len(head) == 0 {
		return reply
	}
	block := strings.Join(head, "\n\n")
	if reply == "" {
		return block
	}
	return block + "\n\n" + reply
}

func (s *SurfaceSink) Bodies() []string {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, len(s.bodies))
	copy(out, s.bodies)
	return out
}
func (e Execution) Allows(name string) bool {
	if e.Capabilities == nil {
		return true
	}
	for _, c := range e.Capabilities {
		if c == name {
			return true
		}
	}
	return false
}

// Budget is a usage counter. Its name and Limit field remain for plugin/config
// compatibility; Limit is deprecated and never enforced.
type Budget struct {
	parent              *Budget
	mu                  sync.Mutex
	Limit, Used         int64
	TokensIn, TokensOut int64
}
type budgetKey struct{}

func WithBudget(ctx context.Context, b *Budget) context.Context {
	return context.WithValue(ctx, budgetKey{}, b)
}
func BudgetFrom(ctx context.Context) *Budget { b, _ := ctx.Value(budgetKey{}).(*Budget); return b }
func (b *Budget) Charge(tokens int64) bool {
	if b == nil {
		return true
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.Used += tokens
	b.parent.Charge(tokens)
	return true
}

// Remaining is retained for older plugins. Usage counters have no ceiling.
func (b *Budget) Remaining() int64 { return 1 << 62 }

// IntersectCapabilities never widens either host or agent policy. Nil is unrestricted.
func IntersectCapabilities(host, agent []string) []string {
	if host == nil {
		return agent
	}
	if agent == nil {
		return host
	}
	out := []string{}
	h := Execution{Capabilities: host}
	for _, name := range agent {
		if h.Allows(name) {
			out = append(out, name)
		}
	}
	return out
}

// WorkingDirectory scopes relative paths to the host-issued execution ID.
func WorkingDirectory(runID string) string {
	if runID == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(runID))
	return "/tmp/aseman/runs/" + hex.EncodeToString(sum[:16])
}

func (b *Budget) Totals() (int64, int64) {
	if b == nil {
		return 0, 0
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.TokensIn, b.TokensOut
}
func (b *Budget) RecordTokens(in, out int64) {
	if b == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.TokensIn += in
	b.TokensOut += out
	b.parent.RecordTokens(in, out)
}
