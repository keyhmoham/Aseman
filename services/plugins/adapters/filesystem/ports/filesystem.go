// Package filesystem defines the driven port for object/file storage plugins
// (local disk, S3, ...). Files are addressed by opaque storage keys.
package filesystem

import (
	"context"
	"io"
	"time"
)

// Config for a storage plugin.
type Config struct {
	BasePath string            `json:"base_path,omitempty"`
	Bucket   string            `json:"bucket,omitempty"`
	Region   string            `json:"region,omitempty"`
	Endpoint string            `json:"endpoint,omitempty"` // for S3-compatible providers
	Options  map[string]string `json:"options,omitempty"`
}

// ObjectInfo describes a stored object.
type ObjectInfo struct {
	Key         string    `json:"key"`
	Size        int64     `json:"size"`
	ContentType string    `json:"content_type,omitempty"`
	Modified    time.Time `json:"modified"`
}

// Health of the storage plugin.
type Health struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

// FileStorage is the driven port implemented by filesystem plugins.
type FileStorage interface {
	Name() string
	Open(ctx context.Context, cfg Config) error
	Close(ctx context.Context) error
	Health(ctx context.Context) Health

	Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Delete(ctx context.Context, key string) error
	Stat(ctx context.Context, key string) (ObjectInfo, error)
	Exists(ctx context.Context, key string) (bool, error)
	List(ctx context.Context, prefix string) ([]ObjectInfo, error)
}
