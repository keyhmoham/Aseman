// Package api defines the plugin contract shared by the plugin host, adapters,
// modules and action plugins. Adapters and actions are themselves plugins so
// the whole system can be re-wired at runtime.
package api

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/cache/ports"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/filesystem/ports"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Type classifies plugins.
type Type string

const (
	// TypeAdapter plugins provide a driven port (database, cache, ...).
	TypeAdapter Type = "adapter"
	// TypeAction plugins provide namespaced actions (service+controller).
	TypeAction Type = "action"
	// TypeModule plugins provide internal service modules.
	TypeModule Type = "module"
)

// Category of an adapter plugin.
type Category string

const (
	CategoryDatabase   Category = "database"
	CategoryCache      Category = "cache"
	CategoryNetwork    Category = "network"
	CategoryFilesystem Category = "filesystem"
	CategoryVMM        Category = "vmm"
	CategoryKeyValue   Category = "keyvalue"
)

// Info describes a plugin statically.
type Info struct {
	Name        string   `json:"name"`
	Type        Type     `json:"type"`
	Category    Category `json:"category,omitempty"`
	Version     string   `json:"version"`
	Description string   `json:"description,omitempty"`
	Provides    []string `json:"provides,omitempty"`
	Requires    []string `json:"requires,omitempty"`
}

// State of a plugin's lifecycle.
type State int

const (
	StateRegistered State = iota
	StateLoaded
	StateInitialized
	StateStarted
	StateStopped
	StateUnloaded
	StateFailed
)

func (s State) String() string {
	switch s {
	case StateRegistered:
		return "registered"
	case StateLoaded:
		return "loaded"
	case StateInitialized:
		return "initialized"
	case StateStarted:
		return "started"
	case StateStopped:
		return "stopped"
	case StateUnloaded:
		return "unloaded"
	case StateFailed:
		return "failed"
	default:
		return "unknown"
	}
}

// Health is the runtime health snapshot of a plugin.
type Health struct {
	OK      bool      `json:"ok"`
	Message string    `json:"message,omitempty"`
	Checked time.Time `json:"checked"`
}

// Entry is the runtime record of one registered plugin.
type Entry struct {
	Plugin        Plugin
	State         State
	StateChanged  time.Time
	RegisteredAt  time.Time
	LastError     string
	ConfigVersion int64
}

// Kernel is the minimal core surface exposed to plugins. Plugins never import
// the kernel implementation; they depend on this interface (dependency
// inversion). The runtime kernel implements it.
type Kernel interface {
	NodeID() identity.NodeID
	Logger() *logger.Logger
	DB() database.Database
	Cache() cache.Cache
	FS() filesystem.FileStorage
	Network() network.Network
	VMM() vmm.VMM
	// VMMFor returns a started VMM adapter supporting the given VM type.
	VMMFor(t vmm.Type) vmm.VMM

	// Registry gives access to the plugin registry (load/unload/inspect).
	Registry() Registry
	// Actions returns the action router (register/deregister actions).
	Actions() ActionRouter
	// Resolve returns the plugin instance providing a capability name.
	Resolve(name string) (any, error)
	// Env returns runtime environment values (node url, secrets, ...).
	Env() map[string]string
	// Proxy forwards an action to the node owning entityRef (or dispatches
	// locally when the entity belongs to this node).
	Proxy(ctx context.Context, entityRef string, namespace, name string, caller Caller, body []byte) (*ActionResponse, error)
}

// Registry is the minimal plugin-registry surface used by plugins.
type Registry interface {
	Register(p Plugin) error
	Unregister(name string) error
	Get(name string) (*Entry, bool)
	GetPlugin(name string) (Plugin, bool)
	List() []*Entry
	ListByType(t Type) []*Entry
}

// ActionRouter is the minimal action routing surface used by plugins.
type ActionRouter interface {
	Register(namespace string, a Action) error
	Deregister(namespace, name string) error
	List(namespace string) []ActionMeta
	Namespaces() []string
	Dispatch(ctx context.Context, namespace, name string, req *ActionRequest) (*ActionResponse, error)
}

// Dependencies is what plugins receive at Init time.
type Dependencies struct {
	Kernel Kernel
	Config map[string]any
	Logger *logger.Logger
	// Global is read-only node configuration shared through the plugin bridge.
	Global map[string]any
}

// Plugin is the interface every tradera plugin implements. The lifecycle is
// deterministic: Init -> Start -> (Stop)* -> Unload, with Update at any point
// while started.
type Plugin interface {
	Info() Info
	Init(ctx context.Context, deps *Dependencies) error
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Unload(ctx context.Context) error
	UpdateConfig(ctx context.Context, cfg map[string]any) error
	CheckHealth(ctx context.Context) Health
}

// ActionMeta is a router descriptor for an action.
type ActionMeta struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Summary   string `json:"summary,omitempty"`
	Needs     string `json:"needs,omitempty"` // permission key, "" => authenticated only
}

// Caller describes the authenticated invoker of an action.
type Caller struct {
	ID   identity.ID `json:"id"`
	Kind string      `json:"kind"` // "user" | "bot"
}

// ActionRequest is the normalized input of an action.
type ActionRequest struct {
	Caller Caller          `json:"caller"`
	Origin identity.NodeID `json:"origin"` // node that forwarded the request
	Body   []byte          `json:"body"`
	Meta   map[string]any  `json:"meta,omitempty"`
}

// ActionResponse is the normalized output of an action.
type ActionResponse struct {
	Status int    `json:"status"`
	Body   []byte `json:"body,omitempty"`
}

// Action is a single callable unit inside a namespace. Actions are the
// service+controller unit: they own business logic and return a serializable
// response consumed by any network protocol.
type Action interface {
	Meta() ActionMeta
	Handle(ctx context.Context, req *ActionRequest) (*ActionResponse, error)
}

// Factory is the symbol external Go-plugin binaries must export: New returns a
// fresh plugin instance.
type Factory func() (Plugin, error)

// ServiceProvider publishes an internally wired namespace through the bridge.
// Acquire pins the instance until release; Stop rejects new calls and drains pins.
type ServiceProvider interface {
	Acquire(ctx context.Context) (service any, release func(), err error)
}

// Runtime is the host control surface available to administration plugins.
// It exposes lifecycle operations without importing the kernel implementation.
type Runtime interface {
	Kernel
	Init(string) error
	Start(string) error
	Stop(string) error
	Unload(string) error
	Update(string, map[string]any) error
	SetActive(Category, string) error
	Active(Category) string
	LoadPlugin(context.Context, string, map[string]any) (Info, error)
	BuildPlugin(context.Context, string, string) (string, error)
	ReplacePlugin(context.Context, string, string, map[string]any) (Info, error)
}

// ScopedServiceProvider binds cancellation to the namespace lifetime.
type ScopedServiceProvider interface {
	AcquireContext(context.Context) (any, context.Context, func(), error)
}

// NetworkBindings lets a plugin own protocol-neutral routes across provider changes.
type NetworkBindings interface {
	BindRoutes(owner string, bind func(network.Network) error, unbind func(network.Network) error) (func(), error)
}

// Bootstrapper is an optional plugin-owned initialization hook run after all plugins start.
type Bootstrapper interface{ Bootstrap(context.Context) error }

// NodeIdentity is the fixed host identity and plugin-supplied bootstrap environment.
type NodeIdentity struct {
	ID, PrivateKey, PublicKey string
	Env                       map[string]string
}

// IdentityProvisioner optionally prepares the node identity before services initialize.
type IdentityProvisioner interface {
	PrepareIdentity(context.Context, map[string]any, *logger.Logger) (NodeIdentity, error)
}

// ProxyHandler is a plugin-supplied remote action transport.
type ProxyHandler func(context.Context, string, string, string, Caller, []byte) (*ActionResponse, error)
type ProxyBindings interface {
	BindProxy(string, ProxyHandler) (func(), error)
}
