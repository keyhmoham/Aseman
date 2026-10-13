package vmm

import (
	"context"
	"sync"
)

// Reservation records provider usage without admitting, delaying or rejecting
// requests based on accumulated tokens. MaxOutput bounds one provider response,
// not the lifetime of an agent or workflow.
type Reservation struct {
	budget    *Budget
	once      sync.Once
	MaxOutput int64
}

func (b *Budget) Reserve(ctx context.Context, input int64) (*Reservation, error) {
	return b.ReserveOutput(ctx, input, 4096)
}

// Scope creates an invocation-local usage counter linked to its parent.
// The legacy limit argument is ignored; token usage never terminates execution.
func (b *Budget) Scope(_ int64) *Budget { return &Budget{parent: b} }

func (b *Budget) ReserveOutput(ctx context.Context, _ int64, maxOutput int64) (*Reservation, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if maxOutput <= 0 {
		maxOutput = 4096
	}
	return &Reservation{budget: b, MaxOutput: maxOutput}, nil
}

func (r *Reservation) Finish(in, out int64) bool {
	r.once.Do(func() {
		r.budget.Charge(in + out)
		r.budget.RecordTokens(in, out)
	})
	return true
}
