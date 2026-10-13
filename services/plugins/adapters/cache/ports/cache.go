// Package cache defines the driven port for cache plugins (local, redis, ...).
package cache

import (
	"context"
	"time"
)

// Config is cache plugin configuration.
type Config struct {
	Addr     string            `json:"addr,omitempty"`
	Password string            `json:"password,omitempty"`
	DB       int               `json:"db,omitempty"`
	TTL      time.Duration     `json:"ttl,omitempty"`
	MaxSize  int64             `json:"max_size,omitempty"` // bytes
	Options  map[string]string `json:"options,omitempty"`
}

// Health of the cache plugin.
type Health struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

// Cache is the driven port implemented by cache plugins.
type Cache interface {
	Name() string
	Open(ctx context.Context, cfg Config) error
	Close(ctx context.Context) error
	Health(ctx context.Context) Health

	Get(ctx context.Context, key string) ([]byte, error)
	Set(ctx context.Context, key string, value []byte, ttl time.Duration) error
	Delete(ctx context.Context, key string) error
	// Exists reports key presence.
	Exists(ctx context.Context, key string) (bool, error)
	// Keys returns keys matching a glob pattern (e.g. "sess:*").
	Keys(ctx context.Context, pattern string) ([]string, error)
	// Flush removes all keys with the given prefix.
	FlushPrefix(ctx context.Context, prefix string) (int, error)

	// Lock acquires a distributed lock; returns a release func.
	Lock(ctx context.Context, key string, ttl time.Duration) (func(), error)
}
