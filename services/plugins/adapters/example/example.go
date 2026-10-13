// Package example demonstrates an adapter providing a custom capability
// without adding provider-specific logic or types to the fixed core.
package example

import (
	"context"
	"sync"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/base"
)

type Adapter struct {
	base.Base
	mu      sync.RWMutex
	prefix  string
	running bool
}

func New() api.Plugin {
	return &Adapter{Base: base.Base{Name: "example-adapter", Category: api.CategoryKeyValue, Version: "1.0.0", Provides: []string{"example/greeting"}, Description: "Sample configurable greeting provider"}}
}
func (a *Adapter) Init(ctx context.Context, d *api.Dependencies) error {
	a.Log = d.Logger
	return a.UpdateConfig(ctx, d.Config)
}
func (a *Adapter) Start(context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.running = true
	return nil
}
func (a *Adapter) Stop(context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.running = false
	return nil
}
func (a *Adapter) Unload(ctx context.Context) error { return a.Stop(ctx) }
func (a *Adapter) UpdateConfig(ctx context.Context, cfg map[string]any) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	prefix := "Hello"
	if value, present := cfg["prefix"]; present {
		var ok bool
		prefix, ok = value.(string)
		if !ok {
			return errs.InvalidArgument("prefix must be a string")
		}
	}
	a.prefix = prefix
	return nil
}
func (a *Adapter) Greeting(ctx context.Context, name string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	if !a.running {
		return "", errs.New(errs.CodeUnavailable, "greeting provider stopped")
	}
	return a.prefix + ", " + name + "!", nil
}
