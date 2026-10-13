// Package registry stores the plugin instances and their lifecycle states.
// It is a thread-safe capability store: plugins can be registered, queried by
// name/type and unregistered at any time (reprogrammable wiring).
package registry

import (
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
)

// Entry is the runtime record of one plugin.
type Entry = api.Entry

// Registry holds all plugin entries.
type Registry struct {
	mu      sync.RWMutex
	entries map[string]*Entry
	order   []string
}

// New creates an empty registry.
func New() *Registry {
	return &Registry{entries: map[string]*Entry{}}
}

// Register adds a plugin in the registered state.
func (r *Registry) Register(p api.Plugin) error {
	if p == nil || p.Info().Name == "" {
		return errs.InvalidArgument("plugin must have a name")
	}
	info := p.Info()
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entries[info.Name]; ok {
		return errs.AlreadyExists("plugin " + info.Name + " already registered")
	}
	now := time.Now().UTC()
	r.entries[info.Name] = &Entry{
		Plugin:       p,
		State:        api.StateRegistered,
		StateChanged: now,
		RegisteredAt: now,
	}
	r.order = append(r.order, info.Name)
	return nil
}

// Unregister removes a plugin entry.
func (r *Registry) Unregister(name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entries[name]; !ok {
		return errs.NotFound("plugin " + name + " not registered")
	}
	delete(r.entries, name)
	for i, n := range r.order {
		if n == name {
			r.order = append(r.order[:i], r.order[i+1:]...)
			break
		}
	}
	return nil
}

// Get returns the entry of a plugin.
func (r *Registry) Get(name string) (*Entry, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[name]
	if !ok {
		return nil, false
	}
	copy := *e
	return &copy, true
}

// GetPlugin returns the plugin instance by name.
func (r *Registry) GetPlugin(name string) (api.Plugin, bool) {
	e, ok := r.Get(name)
	if !ok {
		return nil, false
	}
	return e.Plugin, true
}

// List returns all entries in registration order.
func (r *Registry) List() []*Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]*Entry, 0, len(r.order))
	for _, n := range r.order {
		if e, ok := r.entries[n]; ok {
			copy := *e
			out = append(out, &copy)
		}
	}
	return out
}

// ListByType returns entries filtered by type.
func (r *Registry) ListByType(t api.Type) []*Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*Entry
	for _, n := range r.order {
		e := r.entries[n]
		if e.Plugin.Info().Type == t {
			copy := *e
			out = append(out, &copy)
		}
	}
	return out
}

// SetState records a lifecycle transition.
func (r *Registry) SetState(name string, s api.State, err error) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entries[name]
	if !ok {
		return errs.NotFound("plugin " + name + " not registered")
	}
	e.State = s
	e.StateChanged = time.Now().UTC()
	if err != nil {
		e.LastError = err.Error()
	}
	return nil
}

// BumpConfig increments the config version (used on Update).
func (r *Registry) BumpConfig(name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entries[name]
	if !ok {
		return errs.NotFound("plugin " + name + " not registered")
	}
	e.ConfigVersion++
	return nil
}
