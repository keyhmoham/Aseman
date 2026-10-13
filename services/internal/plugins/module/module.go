// Package module implements the shared action-plugin lifecycle. Namespace
// factories own service construction, DTOs, models, internal wiring and workers.
package module

import (
	"context"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

type Instance struct {
	Service   any
	Actions   []api.Action
	Models    []database.Model
	Mount     func(context.Context) error
	Bootstrap func(context.Context) error
	Bind      func(context.Context)
	Run       func(context.Context)
	Close     func(context.Context) error
}
type Factory func(context.Context, *api.Dependencies) (Instance, error)

type Plugin struct {
	mu         sync.Mutex
	info       api.Info
	factory    Factory
	deps       *api.Dependencies
	instance   Instance
	started    bool
	draining   bool
	cancel     context.CancelFunc
	lifetime   context.Context
	active     int
	idle       chan struct{}
	workerDone chan struct{}
}

func New(info api.Info, factory Factory) *Plugin {
	info.Type = api.TypeAction
	return &Plugin{info: info, factory: factory}
}
func (p *Plugin) Info() api.Info { return p.info }
func (p *Plugin) Init(ctx context.Context, deps *api.Dependencies) error {
	p.mu.Lock()
	busy := p.started || p.draining
	p.mu.Unlock()
	if busy {
		return errs.Conflict("namespace must finish stopping before initialization")
	}
	instance, err := p.factory(ctx, deps)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.deps = deps
	p.instance = instance
	return nil
}
func (p *Plugin) Start(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.draining {
		return errs.Conflict("namespace is draining")
	}
	if p.started {
		return nil
	}
	if p.deps == nil {
		return errs.New(errs.CodePlugin, "plugin not initialized")
	}
	db := p.deps.Kernel.DB()
	if len(p.instance.Models) > 0 && db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	for _, model := range p.instance.Models {
		if err := db.RegisterModel(ctx, model); err != nil {
			return err
		}
	}
	registered := []api.ActionMeta{}
	for _, action := range p.instance.Actions {
		if err := p.deps.Kernel.Actions().Register(action.Meta().Namespace, &guardedAction{plugin: p, action: action}); err != nil {
			for _, meta := range registered {
				_ = p.deps.Kernel.Actions().Deregister(meta.Namespace, meta.Name)
			}
			return err
		}
		registered = append(registered, action.Meta())
	}
	p.started = true
	workerCtx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel
	p.lifetime = workerCtx
	p.workerDone = make(chan struct{})
	done := p.workerDone
	instance := p.instance
	if instance.Mount != nil {
		if err := instance.Mount(workerCtx); err != nil {
			cancel()
			p.started = false
			for _, action := range instance.Actions {
				meta := action.Meta()
				_ = p.deps.Kernel.Actions().Deregister(meta.Namespace, meta.Name)
			}
			close(done)
			return err
		}
	}
	if instance.Bind != nil {
		instance.Bind(workerCtx)
	}
	go func() {
		defer close(done)
		if instance.Run != nil {
			instance.Run(workerCtx)
		}
	}()
	return nil
}
func (p *Plugin) Acquire(ctx context.Context) (any, func(), error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.started {
		return nil, nil, errs.New(errs.CodeUnavailable, "namespace is stopped: "+p.info.Name)
	}
	if p.active == 0 {
		p.idle = make(chan struct{})
	}
	p.active++
	var once sync.Once
	release := func() {
		once.Do(func() {
			p.mu.Lock()
			defer p.mu.Unlock()
			p.active--
			if p.active == 0 {
				close(p.idle)
			}
		})
	}
	return p.instance.Service, release, nil
}
func (p *Plugin) Stop(ctx context.Context) error {
	p.mu.Lock()
	if !p.started && !p.draining {
		p.mu.Unlock()
		return nil
	}
	p.started = false
	p.draining = true
	p.cancel()
	for _, action := range p.instance.Actions {
		meta := action.Meta()
		_ = p.deps.Kernel.Actions().Deregister(meta.Namespace, meta.Name)
	}
	idle := p.idle
	active := p.active
	workers := p.workerDone
	p.mu.Unlock()
	// Removing routes prevents new requests before active calls are drained.
	if active > 0 {
		select {
		case <-idle:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	select {
	case <-workers:
	case <-ctx.Done():
		return ctx.Err()
	}
	if p.instance.Close != nil {
		if err := p.instance.Close(ctx); err != nil {
			return err
		}
	}
	p.mu.Lock()
	p.draining = false
	p.mu.Unlock()
	return nil
}
func (p *Plugin) Unload(ctx context.Context) error { return p.Stop(ctx) }
func (p *Plugin) UpdateConfig(ctx context.Context, cfg map[string]any) error {
	if err := p.Stop(ctx); err != nil {
		return err
	}
	p.mu.Lock()
	previous := p.instance
	oldDeps := p.deps
	deps := *oldDeps
	deps.Config = cfg
	p.mu.Unlock()
	if err := p.Init(ctx, &deps); err != nil {
		p.mu.Lock()
		p.instance = previous
		p.deps = oldDeps
		p.mu.Unlock()
		_ = p.Start(ctx)
		return err
	}
	if err := p.Start(ctx); err != nil {
		p.mu.Lock()
		p.instance = previous
		p.deps = oldDeps
		p.mu.Unlock()
		_ = p.Start(ctx)
		return err
	}
	return nil
}
func (p *Plugin) CheckHealth(ctx context.Context) api.Health {
	p.mu.Lock()
	defer p.mu.Unlock()
	return api.Health{OK: p.started, Checked: time.Now().UTC()}
}

type guardedAction struct {
	plugin *Plugin
	action api.Action
}

func (a *guardedAction) Meta() api.ActionMeta { return a.action.Meta() }
func (a *guardedAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	_, ctx, release, err := a.plugin.AcquireContext(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	return a.action.Handle(ctx, req)
}

func (p *Plugin) AcquireContext(ctx context.Context) (any, context.Context, func(), error) {
	service, release, err := p.Acquire(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	p.mu.Lock()
	lifetime := p.lifetime
	p.mu.Unlock()
	call, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(lifetime, cancel)
	if lifetime.Err() != nil {
		cancel()
	}
	return service, call, func() { stop(); cancel(); release() }, nil
}

func (p *Plugin) Bootstrap(ctx context.Context) error {
	_, ctx, release, err := p.AcquireContext(ctx)
	if err != nil {
		return err
	}
	defer release()
	p.mu.Lock()
	hook := p.instance.Bootstrap
	p.mu.Unlock()
	if hook != nil {
		return hook(ctx)
	}
	return nil
}
