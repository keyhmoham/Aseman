// Package redis implements the cache port backed by a Redis server.
package redis

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cache/ports"
	"github.com/aseman/aseman/plugins/adapters/cfg"

	"github.com/redis/go-redis/v9"
)

// Adapter is the Redis cache plugin.
type Adapter struct {
	base.Base
	client *redis.Client
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "redis",
			Category:    api.CategoryCache,
			Version:     "1.0.0",
			Description: "Redis key-value cache provider",
			Provides:    []string{"cache"},
			Log:         log,
		},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Cache(deps.Config)
	return a.Open(ctx, c)
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return nil }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements cache.Cache.
func (a *Adapter) Name() string { return "redis" }

// Open implements cache.Cache.
func (a *Adapter) Open(ctx context.Context, c cache.Config) error {
	if c.Addr == "" {
		return errs.InvalidArgument("redis adapter requires config.addr (host:port)")
	}
	a.client = redis.NewClient(&redis.Options{Addr: c.Addr, Password: c.Password, DB: c.DB})
	if err := a.client.Ping(ctx).Err(); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "ping redis")
	}
	return nil
}

// Close implements cache.Cache.
func (a *Adapter) Close(ctx context.Context) error {
	if a.client != nil {
		return a.client.Close()
	}
	return nil
}

// Health implements cache.Cache.
func (a *Adapter) Health(ctx context.Context) cache.Health {
	if a.client == nil {
		return cache.Health{OK: false, Message: "redis not open"}
	}
	if err := a.client.Ping(ctx).Err(); err != nil {
		return cache.Health{OK: false, Message: err.Error()}
	}
	return cache.Health{OK: true, Message: "redis healthy"}
}

// Get implements cache.Cache.
func (a *Adapter) Get(ctx context.Context, key string) ([]byte, error) {
	b, err := a.client.Get(ctx, key).Bytes()
	if err == redis.Nil {
		return nil, errs.NotFound("cache key " + key)
	}
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "redis get")
	}
	return b, nil
}

// Set implements cache.Cache.
func (a *Adapter) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	if err := a.client.Set(ctx, key, value, ttl).Err(); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "redis set")
	}
	return nil
}

// Delete implements cache.Cache.
func (a *Adapter) Delete(ctx context.Context, key string) error {
	if err := a.client.Del(ctx, key).Err(); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "redis del")
	}
	return nil
}

// Exists implements cache.Cache.
func (a *Adapter) Exists(ctx context.Context, key string) (bool, error) {
	n, err := a.client.Exists(ctx, key).Result()
	if err != nil {
		return false, errs.Wrap(errs.CodePlugin, err, "redis exists")
	}
	return n > 0, nil
}

// Keys implements cache.Cache.
func (a *Adapter) Keys(ctx context.Context, pattern string) ([]string, error) {
	out, err := a.client.Keys(ctx, pattern).Result()
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "redis keys")
	}
	return out, nil
}

// FlushPrefix implements cache.Cache.
func (a *Adapter) FlushPrefix(ctx context.Context, prefix string) (int, error) {
	keys, err := a.Keys(ctx, prefix+"*")
	if err != nil {
		return 0, err
	}
	if len(keys) == 0 {
		return 0, nil
	}
	if err := a.client.Del(ctx, keys...).Err(); err != nil {
		return 0, errs.Wrap(errs.CodePlugin, err, "redis flush")
	}
	return len(keys), nil
}

// Lock implements cache.Cache via SET NX EX.
func (a *Adapter) Lock(ctx context.Context, key string, ttl time.Duration) (func(), error) {
	lockKey := "lock:" + key
	tok, err := idutil.RandomHex(8)
	if err != nil {
		return nil, err
	}
	ok, err := a.client.SetNX(ctx, lockKey, tok, ttl).Result()
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "redis lock")
	}
	if !ok {
		return nil, errs.New(errs.CodeConflict, "lock held: "+key)
	}
	released := false
	return func() {
		if released {
			return
		}
		// Compare-and-delete to avoid releasing someone else's lock.
		if v, err := a.client.Get(ctx, lockKey).Result(); err == nil && v == tok {
			_ = a.client.Del(ctx, lockKey).Err()
		}
		released = true
	}, nil
}
