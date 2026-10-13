// Package base provides embeddable scaffolding for adapter plugins so each
// adapter only implements its provider logic and its port interface.
package base

import (
	"context"
	"reflect"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/logger"
)

// Base is embedded into adapter plugins.
type Base struct {
	Name        string
	Category    api.Category
	Version     string
	Description string
	Provides    []string
	Log         *logger.Logger
	// HealthCheck overrides the default healthy report (set via WireHealth).
	HealthCheck func(ctx context.Context) api.Health
}

// CheckHealth implements api.Plugin.
func (b *Base) CheckHealth(ctx context.Context) api.Health {
	if b.HealthCheck != nil {
		return b.HealthCheck(ctx)
	}
	return b.Healthy()
}

// WireHealth adapts a port health function into an api.Health function by
// reading the OK and Message fields through reflection.
func WireHealth[T any](fn func(ctx context.Context) T) func(ctx context.Context) api.Health {
	return func(ctx context.Context) api.Health {
		out := api.Health{Checked: time.Now().UTC()}
		v := reflect.ValueOf(fn(ctx))
		if f := v.FieldByName("OK"); f.IsValid() && f.Kind() == reflect.Bool {
			out.OK = f.Bool()
		}
		if f := v.FieldByName("Message"); f.IsValid() && f.Kind() == reflect.String {
			out.Message = f.String()
		}
		return out
	}
}

// Info implements api.Plugin.
func (b *Base) Info() api.Info {
	return api.Info{
		Name:        b.Name,
		Type:        api.TypeAdapter,
		Category:    b.Category,
		Version:     b.Version,
		Description: b.Description,
		Provides:    b.Provides,
	}
}

// Unload implements api.Plugin (no-op default).
func (b *Base) Unload(ctx context.Context) error { return nil }

// Update implements api.Plugin (no-op default).
func (b *Base) UpdateConfig(ctx context.Context, cfg map[string]any) error { return nil }

// Healthy builds a positive health report.
func (b *Base) Healthy() api.Health {
	return api.Health{OK: true, Checked: time.Now().UTC()}
}

// Unhealthy builds a negative health report.
func (b *Base) Unhealthy(msg string) api.Health {
	return api.Health{OK: false, Message: msg, Checked: time.Now().UTC()}
}
