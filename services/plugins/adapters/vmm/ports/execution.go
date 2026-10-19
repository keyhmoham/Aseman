package vmm

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	return "/tmp/tradera/runs/" + hex.EncodeToString(sum[:16])
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
