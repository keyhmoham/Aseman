// Package manager drives plugin lifecycle transitions in a fault tolerant
// manner: a plugin that fails a transition is marked failed (never panics the
// process), is kept inspectable, and can be retried or unloaded.
package manager

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/registry"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
)

// Manager orchestrates plugin lifecycle.
type Manager struct {
	reg        *registry.Registry
	log        *logger.Logger
	mu         sync.Mutex
	operations sync.Map
}

// New creates a manager bound to a registry.
func New(reg *registry.Registry, log *logger.Logger) *Manager {
	return &Manager{reg: reg, log: log.Named("plugins")}
}

// Lock lifecycle operations per plugin; unrelated plugins can transition independently.
func (m *Manager) lock(name string) func() {
	value, _ := m.operations.LoadOrStore(name, &sync.Mutex{})
	mu := value.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// allowed maps a transition source state to allowed target states.
var allowed = map[api.State]map[api.State]bool{
	api.StateRegistered:  {api.StateLoaded: true, api.StateInitialized: true, api.StateUnloaded: true},
	api.StateLoaded:      {api.StateInitialized: true, api.StateUnloaded: true},
	api.StateInitialized: {api.StateStarted: true, api.StateUnloaded: true},
	api.StateStarted:     {api.StateStopped: true, api.StateUnloaded: true},
	api.StateStopped:     {api.StateStarted: true, api.StateUnloaded: true},
	api.StateFailed:      {api.StateStopped: true, api.StateUnloaded: true, api.StateLoaded: true, api.StateInitialized: true},
	api.StateUnloaded:    {},
}

func (m *Manager) transition(name string, target api.State) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if !allowed[e.State][target] {
		return errs.New(errs.CodeConflict,
			fmt.Sprintf("invalid transition %s -> %s for plugin %s", e.State, target, name))
	}
	return nil
}

// Register adds a plugin to the registry (state: registered).
func (m *Manager) Register(p api.Plugin) error {
	if err := m.reg.Register(p); err != nil {
		return err
	}
	m.log.Info("plugin registered", "name", p.Info().Name, "type", p.Info().Type)
	return nil
}

// Load advances a plugin to loaded (just a registry state marker here; external
// plugins are materialized before registration).
func (m *Manager) Load(name string) error {
	unlock := m.lock(name)
	defer unlock()
	if err := m.transition(name, api.StateLoaded); err != nil {
		return err
	}
	return m.reg.SetState(name, api.StateLoaded, nil)
}

// Init runs a plugin's Init with the provided dependencies.
func (m *Manager) Init(name string, deps *api.Dependencies) error {
	unlock := m.lock(name)
	defer unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if e.State == api.StateInitialized || e.State == api.StateStarted || e.State == api.StateStopped {
		return nil
	}
	if err := m.transition(name, api.StateInitialized); err != nil {
		return err
	}
	m.log.Info("initializing plugin", "name", name)
	if err := e.Plugin.Init(context.Background(), deps); err != nil {
		_ = m.reg.SetState(name, api.StateFailed, err)
		return errs.Wrap(errs.CodePlugin, err, "init plugin "+name)
	}
	return m.reg.SetState(name, api.StateInitialized, nil)
}

// Start runs a plugin's Start.
func (m *Manager) Start(name string) error {
	unlock := m.lock(name)
	defer unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if e.State == api.StateStarted {
		return nil
	}
	if err := m.transition(name, api.StateStarted); err != nil {
		return err
	}
	m.log.Info("starting plugin", "name", name)
	if err := e.Plugin.Start(context.Background()); err != nil {
		_ = m.reg.SetState(name, api.StateFailed, err)
		return errs.Wrap(errs.CodePlugin, err, "start plugin "+name)
	}
	return m.reg.SetState(name, api.StateStarted, nil)
}

// Stop runs a plugin's Stop.
func (m *Manager) Stop(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return m.StopContext(ctx, name)
}

func (m *Manager) StopContext(ctx context.Context, name string) error {
	unlock := m.lock(name)
	defer unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if e.State == api.StateStopped {
		return nil
	}
	if err := m.transition(name, api.StateStopped); err != nil {
		return err
	}
	m.log.Info("stopping plugin", "name", name)
	if err := e.Plugin.Stop(ctx); err != nil {
		_ = m.reg.SetState(name, api.StateFailed, err)
		return errs.Wrap(errs.CodePlugin, err, "stop plugin "+name)
	}
	return m.reg.SetState(name, api.StateStopped, nil)
}

// Unload removes a plugin from the registry.
func (m *Manager) Unload(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	unlock := m.lock(name)
	defer unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if err := m.transition(name, api.StateUnloaded); err != nil {
		return err
	}
	if e.State != api.StateUnloaded {
		if err := e.Plugin.Unload(ctx); err != nil {
			_ = m.reg.SetState(name, api.StateFailed, err)
			return errs.Wrap(errs.CodePlugin, err, "unload plugin "+name)
		}
	}
	_ = m.reg.SetState(name, api.StateUnloaded, nil)
	if err := m.reg.Unregister(name); err != nil {
		return err
	}
	m.log.Info("plugin unloaded", "name", name)
	return nil
}

// Update pushes new config to a plugin while it is running.
func (m *Manager) Update(name string, cfg map[string]any) error {
	unlock := m.lock(name)
	defer unlock()
	e, ok := m.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if e.State != api.StateStarted {
		return errs.New(errs.CodeConflict, "plugin "+name+" must be started to update")
	}
	if err := e.Plugin.UpdateConfig(context.Background(), cfg); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "update plugin "+name)
	}
	_ = m.reg.BumpConfig(name)
	m.log.Info("plugin updated", "name", name)
	return nil
}

// Boot initializes and starts plugins in dependency-safe order (topological
// order of Requires/Provides; plugins with satisfied deps first). Failing
// plugins are skipped and reported, never aborting the whole boot.
func (m *Manager) Boot(ctx context.Context, depsFactory func(name string) *api.Dependencies, names []string) error {
	plan, err := m.planOrder(names)
	if err != nil {
		return err
	}
	var failed []string
	for _, name := range plan {
		deps := &api.Dependencies{Config: map[string]any{}}
		if depsFactory != nil {
			deps = depsFactory(name)
		}
		if err := m.Init(name, deps); err != nil {
			failed = append(failed, name)
			m.log.Error("init failed", "plugin", name, "error", err)
			continue
		}
		if err := m.Start(name); err != nil {
			failed = append(failed, name)
			m.log.Error("start failed", "plugin", name, "error", err)
		}
	}
	if len(failed) > 0 {
		return errs.New(errs.CodePlugin, fmt.Sprintf("plugins failed to boot: %v", failed))
	}
	return nil
}

// Shutdown stops all started plugins in reverse registration order.
func (m *Manager) Shutdown(ctx context.Context) error {
	var errsOut []error
	for _, kind := range []api.Type{api.TypeAction, api.TypeModule, api.TypeAdapter} {
		entries := m.reg.ListByType(kind)
		for i := len(entries) - 1; i >= 0; i-- {
			e := entries[i]
			if e.State != api.StateStarted {
				continue
			}
			if err := m.Stop(e.Plugin.Info().Name); err != nil {
				errsOut = append(errsOut, err)
			}
		}
	}

	if len(errsOut) > 0 {
		return errs.Wrap(errs.CodePlugin, fmt.Errorf("%v", errsOut), "shutdown")
	}
	return nil
}

// planOrder returns names ordered so that providers come before consumers.
func (m *Manager) planOrder(names []string) ([]string, error) {
	entries := map[string]*registry.Entry{}
	var order []string
	for _, n := range names {
		e, ok := m.reg.Get(n)
		if !ok {
			return nil, errs.NotFound("plugin " + n)
		}
		entries[n] = e
		order = append(order, n)
	}
	// Simple provider-first sort: stable by registration order, providers first.
	sorted := make([]string, 0, len(order))
	added := map[string]bool{}
	for len(sorted) < len(order) {
		progress := false
		for _, n := range order {
			if added[n] {
				continue
			}
			info := entries[n].Plugin.Info()
			reqsOK := true
			for _, req := range info.Requires {
				if _, ok := entries[req]; ok && !added[req] {
					reqsOK = false
					break
				}
			}
			if reqsOK {
				sorted = append(sorted, n)
				added[n] = true
				progress = true
			}
		}
		if !progress {
			for _, n := range order {
				if !added[n] {
					sorted = append(sorted, n)
					added[n] = true
				}
			}
		}
	}
	return sorted, nil
}

// Order returns the lifecycle dependency order used by the host.
func (m *Manager) Order(names []string) ([]string, error) { return m.planOrder(names) }
