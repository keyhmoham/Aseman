package lifetime

import (
	"context"
	"sync"

	"github.com/aseman/aseman/pkg/errs"
)

// Gate prevents closing a provider under an operation and cancels
// outstanding operations before draining. No provider-specific logic lives here.
type Gate struct {
	mu       sync.Mutex
	running  bool
	lifetime context.Context
	cancel   context.CancelFunc
	active   int
	idle     chan struct{}
}

func (g *Gate) Start() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.running {
		return
	}
	g.lifetime, g.cancel = context.WithCancel(context.Background())
	g.running = true
}
func (g *Gate) Acquire(ctx context.Context) (context.Context, func(), error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.running {
		return nil, nil, errs.New(errs.CodeUnavailable, "adapter is stopped or draining")
	}
	if g.active == 0 {
		g.idle = make(chan struct{})
	}
	g.active++
	operation, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(g.lifetime, cancel)
	var once sync.Once
	release := func() {
		once.Do(func() {
			stop()
			cancel()
			g.mu.Lock()
			defer g.mu.Unlock()
			g.active--
			if g.active == 0 {
				close(g.idle)
			}
		})
	}
	return operation, release, nil
}
func (g *Gate) Drain(ctx context.Context) error {
	g.mu.Lock()
	g.running = false
	if g.cancel != nil {
		g.cancel()
	}
	active, idle := g.active, g.idle
	g.mu.Unlock()
	if active > 0 {
		select {
		case <-idle:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}
