package vmm

import (
	"context"
	"sync"

	"github.com/aseman/aseman/plugins/actions/usage/models/usage"
)

type invocationKey struct{}

// InvocationUsage carries exact per-invocation usage, including failed calls.
type InvocationUsage struct {
	mu               sync.Mutex
	Delta            usage.Delta
	billed, recorded bool
}

func WithInvocationUsage(ctx context.Context) context.Context {
	return context.WithValue(ctx, invocationKey{}, &InvocationUsage{})
}

func InvocationFrom(ctx context.Context) *InvocationUsage {
	u, _ := ctx.Value(invocationKey{}).(*InvocationUsage)
	return u
}

func AddInvocationUsage(ctx context.Context, d usage.Delta) {
	if u := InvocationFrom(ctx); u != nil {
		u.mu.Lock()
		u.Delta.TokensIn += d.TokensIn
		u.Delta.TokensOut += d.TokensOut
		u.Delta.Images += d.Images
		u.Delta.ImageCount += d.ImageCount
		u.Delta.ImageIn += d.ImageIn
		u.Delta.ImageOut += d.ImageOut
		if d.ImageModel != "" {
			u.Delta.ImageModel = d.ImageModel
		}
		u.Delta.Decision += d.Decision
		u.Delta.DecisionIn += d.DecisionIn
		u.Delta.DecisionOut += d.DecisionOut
		u.mu.Unlock()
	}
}

func (u *InvocationUsage) Take(billing bool) usage.Delta {
	u.mu.Lock()
	defer u.mu.Unlock()
	if billing {
		if u.billed {
			return usage.Delta{}
		}
		u.billed = true
	} else {
		if u.recorded {
			return usage.Delta{}
		}
		u.recorded = true
	}
	return u.Delta
}
