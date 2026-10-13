package runtime

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/lifetime"
	"github.com/tradera/tradera/plugins/adapters/cache/ports"
)

type guardedCache struct {
	port cache.Cache
	gate *lifetime.Gate
}

func (p *guardedCache) Name() string {
	var zero0 string
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.Name()
}
func (p *guardedCache) Open(ctx context.Context, cfg cache.Config) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Open(ctx, cfg)
}
func (p *guardedCache) Close(ctx context.Context) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Close(ctx)
}
func (p *guardedCache) Health(ctx context.Context) cache.Health {
	var zero0 cache.Health
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0
	}
	defer release()
	ctx = operationCtx
	return p.port.Health(ctx)
}
func (p *guardedCache) Get(ctx context.Context, key string) ([]byte, error) {
	var zero0 []byte
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Get(ctx, key)
}
func (p *guardedCache) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Set(ctx, key, value, ttl)
}
func (p *guardedCache) Delete(ctx context.Context, key string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Delete(ctx, key)
}
func (p *guardedCache) Exists(ctx context.Context, key string) (bool, error) {
	var zero0 bool
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Exists(ctx, key)
}
func (p *guardedCache) Keys(ctx context.Context, pattern string) ([]string, error) {
	var zero0 []string
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Keys(ctx, pattern)
}
func (p *guardedCache) FlushPrefix(ctx context.Context, prefix string) (int, error) {
	var zero0 int
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.FlushPrefix(ctx, prefix)
}
func (p *guardedCache) Lock(ctx context.Context, key string, ttl time.Duration) (func(), error) {
	var zero0 func()
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Lock(ctx, key, ttl)
}

func Guard(port cache.Cache, gate *lifetime.Gate) cache.Cache {
	return &guardedCache{port: port, gate: gate}
}
