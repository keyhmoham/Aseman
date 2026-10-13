// Package kernel is the minimal tradera core. It owns no business logic; it
// wires plugins, resolves capabilities, tracks the active adapter per category
// and exposes the action router. Reprogramming is done at runtime: loading or
// unloading adapter plugins changes what Resolve/DB/Cache/... return
// immediately.
package kernel

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/host"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/internal/plugins/manager"
	"github.com/tradera/tradera/internal/plugins/registry"
	"github.com/tradera/tradera/internal/routing"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/cache/ports"
	cacheruntime "github.com/tradera/tradera/plugins/adapters/cache/runtime"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	databaseruntime "github.com/tradera/tradera/plugins/adapters/database/runtime"
	"github.com/tradera/tradera/plugins/adapters/filesystem/ports"
	filesystemruntime "github.com/tradera/tradera/plugins/adapters/filesystem/runtime"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	vmmruntime "github.com/tradera/tradera/plugins/adapters/vmm/runtime"
	"github.com/tradera/tradera/plugins/config"
)

// ProxyFunc forwards an action to the node owning an entity.
type ProxyFunc = api.ProxyHandler

// Kernel wires the platform.
type Kernel struct {
	credentials    map[string]maintenanceCredential
	nodeID         identity.NodeID
	cfg            *dconfig.Provider
	log            *logger.Logger
	logDir         string
	reg            *registry.Registry
	mgr            *manager.Manager
	actions        *router.Router
	env            map[string]string
	proxy          ProxyFunc
	proxyOwner     string
	shared         map[string]any
	global         map[string]any
	sourceRoot     string
	pluginDir      string
	pluginMu       sync.Mutex
	adapterGates   sync.Map
	schemas        map[string]database.Model
	pluginConfigs  map[string]map[string]any
	bindNetwork    func(network.Network) error
	routeMu        sync.Mutex
	routeBindings  map[string]networkBinding
	networkChanged chan struct{}
	networkVersion atomic.Uint64

	mu     sync.RWMutex
	active map[api.Category]string
}

// Options for constructing a kernel.
type Options struct {
	NodeID identity.NodeID
	Config *dconfig.Provider
	Logger *logger.Logger
	Env    map[string]string
	// LogDir enables per-plugin log files.
	LogDir string
}

// New builds a kernel.
func New(opts Options) *Kernel {
	if opts.Logger == nil {
		opts.Logger = logger.Global()
	}
	reg := registry.New()
	k := &Kernel{
		nodeID:         opts.NodeID,
		cfg:            opts.Config,
		log:            opts.Logger.Named("kernel"),
		logDir:         opts.LogDir,
		reg:            reg,
		mgr:            manager.New(reg, opts.Logger),
		actions:        router.New(),
		env:            opts.Env,
		active:         map[api.Category]string{},
		shared:         map[string]any{},
		credentials:    map[string]maintenanceCredential{},
		schemas:        map[string]database.Model{},
		pluginConfigs:  map[string]map[string]any{},
		networkChanged: make(chan struct{}, 1),
	}
	return k
}

// NodeID returns this node's identifier.
func (k *Kernel) NodeID() identity.NodeID { return k.nodeID }

// Logger returns the kernel logger.
func (k *Kernel) Logger() *logger.Logger { return k.log }

// Registry returns the plugin registry.
func (k *Kernel) Registry() api.Registry { return k.reg }

// Actions returns the action router.
func (k *Kernel) Actions() api.ActionRouter { return k.actions }

// ActionRouter returns the concrete router (for the API layer).
func (k *Kernel) ActionRouter() *router.Router { return k.actions }

// Manager returns the plugin lifecycle manager.
func (k *Kernel) Manager() *manager.Manager { return k.mgr }

// Config returns the config provider.
func (k *Kernel) Config() *dconfig.Provider { return k.cfg }

// SetProxy supplies a remote action transport. Plugins normally use BindProxy.
func (k *Kernel) SetProxy(p ProxyFunc) { k.mu.Lock(); defer k.mu.Unlock(); k.proxy = p }

// Proxy forwards an action to the owning node, dispatching locally when the
// entity belongs to this node.
func (k *Kernel) Proxy(ctx context.Context, entityRef string, namespace, name string, caller api.Caller, body []byte) (*api.ActionResponse, error) {
	id, err := identity.Parse(entityRef)
	if err == nil && id.Node != k.NodeID() {
		k.mu.RLock()
		proxy := k.proxy
		k.mu.RUnlock()
		if proxy != nil {
			return proxy(ctx, entityRef, namespace, name, caller, body)
		}
		return nil, errs.New(errs.CodeFederation, "remote action transport not configured")
	}

	return k.actions.Dispatch(ctx, namespace, name, &api.ActionRequest{
		Caller: caller, Origin: k.NodeID(), Body: body,
	})
}

// Env returns runtime environment values.
func (k *Kernel) Env() map[string]string {
	out := make(map[string]string, len(k.env))
	for kk, vv := range k.env {
		out[kk] = vv
	}
	return out
}

// Register registers a plugin and, if it provides an adapter category with no
// active adapter yet, binds it as active.
func (k *Kernel) Register(p api.Plugin) error {
	if err := k.mgr.Register(p); err != nil {
		return err
	}
	info := p.Info()
	if info.Type == api.TypeAdapter && info.Category != "" {
		k.mu.Lock()
		defer k.mu.Unlock()
		if _, ok := k.active[info.Category]; !ok {
			k.active[info.Category] = info.Name
		}
	}
	return nil
}

// Boot initializes and starts the named plugins.
func (k *Kernel) Boot(ctx context.Context, names []string) error {
	order, err := k.mgr.Order(names)
	if err != nil {
		return err
	}
	for _, name := range order {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := k.Init(name); err != nil {
			return err
		}
		if err := k.Start(name); err != nil {
			return err
		}
	}
	return nil
}

// depsFor builds the dependency set a plugin receives, including a per-plugin
// logger that writes to the global sinks plus a dedicated log file.
func (k *Kernel) depsFor(name string) *api.Dependencies {
	log := k.log
	if k.logDir != "" {
		os.MkdirAll(k.logDir, 0o755)
		log = k.log.WithFile(filepath.Join(k.logDir, sanitize(name)+".log"))
	}
	config := map[string]any{}
	if k.cfg != nil {
		config = k.cfg.PluginConfig(name)
	}
	k.mu.RLock()
	if saved, ok := k.pluginConfigs[name]; ok {
		config = saved
	}
	k.mu.RUnlock()
	return &api.Dependencies{
		Kernel: k,
		Config: config,
		Logger: log,
		Global: k.global,
	}
}

func sanitize(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

// Init initializes a single plugin.
func (k *Kernel) Init(name string) error {
	return k.mgr.Init(name, k.depsFor(name))
}

// Start starts a single plugin.
func (k *Kernel) Start(name string) error {
	if err := k.mgr.Start(name); err != nil {
		return err
	}
	if e, ok := k.reg.Get(name); ok {
		if db, ok := e.Plugin.(database.Database); ok {
			k.mu.RLock()
			models := make([]database.Model, 0, len(k.schemas))
			for _, model := range k.schemas {
				models = append(models, model)
			}
			k.mu.RUnlock()
			for _, model := range models {
				if err := db.RegisterModel(context.Background(), model); err != nil {
					_ = k.mgr.Stop(name)
					return err
				}
			}
		}
	}
	if e, ok := k.reg.Get(name); ok && e.Plugin.Info().Type == api.TypeAdapter {
		k.gate(name).Start()
	}
	if e, ok := k.reg.Get(name); ok {
		if net, ok := e.Plugin.(network.Network); ok {
			k.mu.RLock()
			binder := k.bindNetwork
			k.mu.RUnlock()
			if binder != nil {
				if err := binder(net); err != nil {
					_ = k.mgr.Stop(name)
					return err
				}
			}
			if err := k.bindPluginRoutes(net); err != nil {
				_ = k.mgr.Stop(name)
				return err
			}
			k.notifyNetwork()
		}
	}
	return nil
}

// Stop stops a single plugin.
func (k *Kernel) Stop(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := k.drainAdapter(ctx, name); err != nil {
		return err
	}
	err := k.mgr.Stop(name)
	if e, ok := k.reg.Get(name); ok && e.Plugin.Info().Category == api.CategoryNetwork {
		k.notifyNetwork()
	}
	return err
}

// Unload unloads a plugin; if it was the active adapter of its category the
// slot becomes empty until another adapter is loaded.
func (k *Kernel) Unload(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := k.drainAdapter(ctx, name); err != nil {
		return err
	}
	if entry, ok := k.reg.Get(name); ok && entry.State == api.StateStarted {
		if err := k.mgr.StopContext(ctx, name); err != nil {
			return err
		}
	}
	if err := k.mgr.Unload(name); err != nil {
		return err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	for category, active := range k.active {
		if active == name {
			if category == api.CategoryNetwork {
				k.notifyNetwork()
			}
			delete(k.active, category)
		}
	}
	return nil
}

// Update pushes config to a plugin.
func (k *Kernel) Update(name string, cfg map[string]any) error {
	entry, ok := k.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if entry.State != api.StateStarted {
		return errs.Conflict("plugin must be started to update")
	}
	if entry.Plugin.Info().Type == api.TypeAdapter {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		previous := k.depsFor(name)
		if err := k.Stop(name); err != nil {
			return err
		}
		next := *previous
		next.Config = cfg
		initialize := func(deps *api.Dependencies) error {
			if err := entry.Plugin.Init(ctx, deps); err != nil {
				return err
			}
			if err := k.reg.SetState(name, api.StateInitialized, nil); err != nil {
				return err
			}
			return k.Start(name)
		}
		if err := initialize(&next); err != nil {
			_ = entry.Plugin.Stop(ctx)
			if rollbackErr := initialize(previous); rollbackErr != nil {
				return fmt.Errorf("update failed: %v; restore failed: %w", err, rollbackErr)
			}
			return err
		}
		_ = k.reg.BumpConfig(name)
	} else if err := k.mgr.Update(name, cfg); err != nil {
		return err
	}

	k.mu.Lock()
	k.pluginConfigs[name] = cfg
	k.mu.Unlock()
	return nil
}

// SetActive binds the active adapter plugin for a category.
func (k *Kernel) SetActive(category api.Category, name string) error {
	if category == "" {
		return errs.InvalidArgument("category required")
	}
	if name != "" {
		e, ok := k.reg.Get(name)
		if !ok {
			return errs.NotFound("plugin " + name)
		}
		if e.Plugin.Info().Category != category {
			return errs.InvalidArgument(fmt.Sprintf("plugin %s is not a %s adapter", name, category))
		}
		if e.State != api.StateStarted {
			return errs.Conflict("adapter must be started before binding")
		}
		if db, ok := e.Plugin.(database.Database); ok {
			k.mu.RLock()
			models := make([]database.Model, 0, len(k.schemas))
			for _, model := range k.schemas {
				models = append(models, model)
			}
			k.mu.RUnlock()
			for _, model := range models {
				if err := db.RegisterModel(context.Background(), model); err != nil {
					return err
				}
			}
		}
	}
	k.mu.Lock()
	k.active[category] = name
	k.mu.Unlock()
	if category == api.CategoryNetwork {
		k.notifyNetwork()
	}
	return nil
}

// Active returns the active adapter plugin name for a category.
func (k *Kernel) Active(category api.Category) string {
	k.mu.RLock()
	defer k.mu.RUnlock()
	return k.active[category]
}

// Resolve returns the plugin instance providing a capability. For adapter
// categories it returns the currently active adapter.
func (k *Kernel) Resolve(name string) (any, error) {
	k.mu.RLock()
	shared, found := k.shared[name]
	k.mu.RUnlock()
	if found {
		return shared, nil
	}
	cat := api.Category(name)
	switch cat {
	case api.CategoryDatabase, api.CategoryCache, api.CategoryNetwork,
		api.CategoryFilesystem, api.CategoryVMM:
		return k.adapter(cat)
	}
	for _, e := range k.reg.List() {
		if e.State != api.StateStarted {
			continue
		}
		for _, p := range e.Plugin.Info().Provides {
			if p == name {
				info := e.Plugin.Info()
				if info.Type == api.TypeAdapter && k.Active(info.Category) != info.Name {
					continue
				}
				return e.Plugin, nil
			}
		}
	}
	return nil, errs.NotFound("capability " + name)
}

// adapter returns the active adapter for a category (nil if none).
func (k *Kernel) adapter(cat api.Category) (any, error) {
	k.mu.RLock()
	name := k.active[cat]
	k.mu.RUnlock()
	if name == "" {
		return nil, errs.New(errs.CodeUnavailable, "no active "+string(cat)+" adapter")
	}
	e, ok := k.reg.Get(name)
	if !ok {
		return nil, errs.NotFound("active " + string(cat) + " adapter " + name)
	}
	if e.State != api.StateStarted {
		return nil, errs.New(errs.CodeUnavailable, "active adapter is stopped: "+name)
	}
	return e.Plugin, nil
}

// DB returns the active database adapter or nil.
func (k *Kernel) DB() database.Database {
	v, err := k.adapter(api.CategoryDatabase)
	if err != nil {
		return nil
	}
	db, _ := v.(database.Database)
	if db == nil {
		return nil
	}
	return databaseruntime.Guard(db, k.gate(v.(api.Plugin).Info().Name), k.rememberModel, k.forgetModel)
}

// Cache returns the active cache adapter or nil.
func (k *Kernel) Cache() cache.Cache {
	v, err := k.adapter(api.CategoryCache)
	if err != nil {
		return nil
	}
	c, _ := v.(cache.Cache)
	if c == nil {
		return nil
	}
	return cacheruntime.Guard(c, k.gate(v.(api.Plugin).Info().Name))
}

// FS returns the active filesystem adapter or nil.
func (k *Kernel) FS() filesystem.FileStorage {
	v, err := k.adapter(api.CategoryFilesystem)
	if err != nil {
		return nil
	}
	f, _ := v.(filesystem.FileStorage)
	if f == nil {
		return nil
	}
	return filesystemruntime.Guard(f, k.gate(v.(api.Plugin).Info().Name))
}

// Network returns the active network adapter or nil.
func (k *Kernel) Network() network.Network {
	v, err := k.adapter(api.CategoryNetwork)
	if err != nil {
		return nil
	}
	n, _ := v.(network.Network)
	return n
}

// VMM returns the active VMM adapter or nil.
func (k *Kernel) VMM() vmm.VMM {
	v, err := k.adapter(api.CategoryVMM)
	if err != nil {
		return nil
	}
	vm, _ := v.(vmm.VMM)
	if vm == nil {
		return nil
	}
	return vmmruntime.Guard(vm, k.gate(v.(api.Plugin).Info().Name))
}

// VMMFor returns a started VMM adapter that supports the given VM type. This
// lets different bot kinds run side by side (langchain agents, docker sandboxes
// and wasm miniapps) even though only one adapter is the category "active".
func (k *Kernel) VMMFor(t vmm.Type) vmm.VMM {
	for _, e := range k.reg.List() {
		if e.State != api.StateStarted {
			continue
		}
		vm, ok := e.Plugin.(vmm.VMM)
		if !ok {
			continue
		}
		for _, st := range vm.SupportedTypes() {
			if st == t {
				return vmmruntime.Guard(vm, k.gate(e.Plugin.Info().Name))
			}
		}
	}
	return nil
}

// Shutdown stops all started plugins.
func (k *Kernel) Shutdown(ctx context.Context) error {
	for _, kind := range []api.Type{api.TypeAction, api.TypeModule, api.TypeAdapter} {
		entries := k.reg.ListByType(kind)
		for i := len(entries) - 1; i >= 0; i-- {
			e := entries[i]
			if e.State != api.StateStarted && e.State != api.StateFailed {
				continue
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			name := e.Plugin.Info().Name
			if err := k.drainAdapter(ctx, name); err != nil {
				return err
			}
			if err := k.mgr.StopContext(ctx, name); err != nil {
				return err
			}
		}
	}
	return nil
}

// ConfigurePlugins defines the bridge's global configuration and build roots.
func (k *Kernel) ConfigurePlugins(global map[string]any, sourceRoot, pluginDir string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.global = global
	k.sourceRoot = sourceRoot
	k.pluginDir = pluginDir
}

// Provide installs a fixed-core context capability such as the logging sink.
func (k *Kernel) Provide(name string, value any) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.shared[name] = value
}

func (k *Kernel) LoadPlugin(ctx context.Context, path string, cfg map[string]any) (api.Info, error) {
	k.pluginMu.Lock()
	defer k.pluginMu.Unlock()
	p, err := host.NewLoader(k.log).Load(path)
	if err != nil {
		return api.Info{}, err
	}
	return k.loadPlugin(ctx, p, cfg)
}
func (k *Kernel) loadPlugin(ctx context.Context, p api.Plugin, cfg map[string]any) (api.Info, error) {
	if err := ctx.Err(); err != nil {
		return api.Info{}, err
	}
	if err := k.Register(p); err != nil {
		return api.Info{}, err
	}
	deps := k.depsFor(p.Info().Name)
	if cfg != nil {
		deps.Config = cfg
	}
	if err := k.mgr.Init(p.Info().Name, deps); err != nil {
		_ = k.Unload(p.Info().Name)
		return api.Info{}, err
	}
	if err := k.Start(p.Info().Name); err != nil {
		_ = k.Unload(p.Info().Name)
		return api.Info{}, err
	}
	k.mu.Lock()
	k.pluginConfigs[p.Info().Name] = deps.Config
	k.mu.Unlock()
	return p.Info(), nil
}

// ReplacePlugin validates the replacement before draining the current module.
// If initialization fails, the previous implementation is restored and started.
func (k *Kernel) ReplacePlugin(ctx context.Context, name, path string, cfg map[string]any) (api.Info, error) {
	k.pluginMu.Lock()
	defer k.pluginMu.Unlock()
	replacement, err := host.NewLoader(k.log).Load(path)
	if err != nil {
		return api.Info{}, err
	}
	previous, ok := k.reg.Get(name)
	if !ok {
		return api.Info{}, errs.NotFound("plugin " + name)
	}
	oldConfig := k.depsFor(name).Config
	oldInfo, newInfo := previous.Plugin.Info(), replacement.Info()
	if newInfo.Name != name || newInfo.Type != oldInfo.Type || newInfo.Category != oldInfo.Category {
		return api.Info{}, errs.InvalidArgument("replacement name, type and category must match")
	}
	var schemas []database.Model
	if oldDB, ok := previous.Plugin.(database.Database); ok {
		schemas = oldDB.Models()
	}
	active := oldInfo.Type == api.TypeAdapter && k.Active(oldInfo.Category) == name
	if err := k.Unload(name); err != nil {
		return api.Info{}, err
	}
	info, err := k.loadPlugin(ctx, replacement, cfg)
	if err == nil {
		if db, ok := replacement.(database.Database); ok {
			for _, model := range schemas {
				if err = db.RegisterModel(ctx, model); err != nil {
					break
				}
			}
		}
	}
	if err == nil && active {
		err = k.SetActive(oldInfo.Category, name)
	}
	if err == nil {
		return info, nil
	}
	_ = k.Unload(name)
	if _, rollback := k.loadPlugin(context.Background(), previous.Plugin, oldConfig); rollback != nil {
		return api.Info{}, errs.Wrap(errs.CodePlugin, rollback, "replacement failed and rollback failed: "+err.Error())
	}
	if active {
		_ = k.SetActive(oldInfo.Category, name)
	}
	return api.Info{}, err
}

func (k *Kernel) BuildPlugin(ctx context.Context, source, output string) (string, error) {
	if output == "" {
		output = k.pluginDir
	}
	return host.Build(ctx, k.sourceRoot, source, output)
}

func (k *Kernel) rememberModel(model database.Model) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.schemas[model.Name] = model
}
func (k *Kernel) forgetModel(name string) { k.mu.Lock(); defer k.mu.Unlock(); delete(k.schemas, name) }
func (k *Kernel) SetNetworkBinder(bind func(network.Network) error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.bindNetwork = bind
}
func (k *Kernel) NetworkChanges() <-chan struct{} { return k.networkChanged }
func (k *Kernel) NetworkVersion() uint64          { return k.networkVersion.Load() }
func (k *Kernel) notifyNetwork() {
	k.networkVersion.Add(1)
	select {
	case k.networkChanged <- struct{}{}:
	default:
	}
}
