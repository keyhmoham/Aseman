// Package local implements the cache port with an in-process TTL cache. It is
// the default cache (zero configuration).
package local

import (
	"context"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/idutil"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/cache/ports"
	"github.com/tradera/tradera/plugins/adapters/cfg"
)

type entry struct {
	value   []byte
	expires time.Time
}

// Adapter is the in-memory cache plugin.
type Adapter struct {
	base.Base
	mu      sync.RWMutex
	items   map[string]entry
	maxTTL  time.Duration
	maxSize int64
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "local-cache",
			Category:    api.CategoryCache,
			Version:     "1.0.0",
			Description: "In-process TTL key-value cache (default)",
			Provides:    []string{"cache"},
			Log:         log,
		},
		items: map[string]entry{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Cache(deps.Config)
	a.maxTTL = c.TTL
	a.maxSize = c.MaxSize
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return nil }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return nil }

// Name implements cache.Cache.
func (a *Adapter) Name() string { return "local-cache" }

// Open implements cache.Cache.
func (a *Adapter) Open(ctx context.Context, c cache.Config) error {
	a.maxTTL = c.TTL
	a.maxSize = c.MaxSize
	return nil
}

// Close implements cache.Cache.
func (a *Adapter) Close(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.items = map[string]entry{}
	return nil
}

// Health implements cache.Cache.
func (a *Adapter) Health(ctx context.Context) cache.Health {
	return cache.Health{OK: true, Message: "local cache healthy"}
}

func (a *Adapter) gc() {
	now := time.Now()
	for k, e := range a.items {
		if !e.expires.IsZero() && now.After(e.expires) {
			delete(a.items, k)
		}
	}
}

// Get implements cache.Cache.
func (a *Adapter) Get(ctx context.Context, key string) ([]byte, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	e, ok := a.items[key]
	if !ok {
		return nil, errs.NotFound("cache key " + key)
	}
	if !e.expires.IsZero() && time.Now().After(e.expires) {
		delete(a.items, key)
		return nil, errs.NotFound("cache key " + key)
	}
	return e.value, nil
}

// Set implements cache.Cache.
func (a *Adapter) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.maxSize > 0 && int64(len(value)) > a.maxSize {
		return errs.InvalidArgument("cache value exceeds max_size")
	}
	if ttl <= 0 {
		ttl = a.maxTTL
	}
	exp := time.Time{}
	if ttl > 0 {
		exp = time.Now().Add(ttl)
	}
	a.items[key] = entry{value: value, expires: exp}
	return nil
}

// Delete implements cache.Cache.
func (a *Adapter) Delete(ctx context.Context, key string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.items, key)
	return nil
}

// Exists implements cache.Cache.
func (a *Adapter) Exists(ctx context.Context, key string) (bool, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	_, ok := a.items[key]
	return ok, nil
}

// Keys implements cache.Cache with glob matching.
func (a *Adapter) Keys(ctx context.Context, pattern string) ([]string, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	a.gc()
	var out []string
	for k := range a.items {
		if matchGlob(pattern, k) {
			out = append(out, k)
		}
	}
	return out, nil
}

// FlushPrefix implements cache.Cache.
func (a *Adapter) FlushPrefix(ctx context.Context, prefix string) (int, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for k := range a.items {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			delete(a.items, k)
			n++
		}
	}
	return n, nil
}

// Lock implements cache.Cache (single-node best-effort).
func (a *Adapter) Lock(ctx context.Context, key string, ttl time.Duration) (func(), error) {
	lockKey := "lock:" + key
	a.mu.Lock()
	defer a.mu.Unlock()
	if e, ok := a.items[lockKey]; ok && (e.expires.IsZero() || time.Now().Before(e.expires)) {
		return nil, errs.New(errs.CodeConflict, "lock held: "+key)
	}
	tok, err := idutil.RandomHex(8)
	if err != nil {
		return nil, err
	}
	a.items[lockKey] = entry{value: []byte(tok), expires: time.Now().Add(ttl)}
	released := false
	return func() {
		if released {
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		delete(a.items, lockKey)
		released = true
	}, nil
}

func matchGlob(pattern, s string) bool {
	// minimal glob supporting '*' and '?'.
	var (
		px, sx = 0, 0
		star   = -1
		match  = 0
	)
	for sx < len(s) {
		if px < len(pattern) && (pattern[px] == '?' || pattern[px] == s[sx]) {
			px++
			sx++
		} else if px < len(pattern) && pattern[px] == '*' {
			star = px
			match = sx
			px++
		} else if star >= 0 {
			px = star + 1
			match++
			sx = match
		} else {
			return false
		}
	}
	for px < len(pattern) && pattern[px] == '*' {
		px++
	}
	return px == len(pattern)
}
