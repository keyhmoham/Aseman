package models

import (
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"time"
)

// Backend modes of a tool: where its backend runs. Every mode answers MCP
// (tools/list, tools/call), so agents and frontends use all of them alike.
const (
	// ModeExternal is an MCP server someone else runs (URL + credentials).
	ModeExternal = "external"
	// ModeManaged is a backend this node runs as a Nomad service of its own,
	// serving every space it was added to.
	ModeManaged = "managed"
	// ModeInstalled is a backend installed into the sandbox of each space that
	// adds it, serving that space alone.
	ModeInstalled = "installed"
)

// Runtimes a managed or installed backend (and a static frontend) runs on.
const (
	RuntimeElpian  = "elpian"  // Elpian VM: Dart or the JS subset, as bytecode
	RuntimeQuickJS = "quickjs" // plain JavaScript on QuickJS
	RuntimeDocker  = "docker"  // a docker image serving MCP on its port
)

// Frontend modes of a tool.
const (
	FrontendNone       = ""
	FrontendStatic     = "static"     // an Elpian miniapp: a program on the Elpian VM or QuickJS
	FrontendGenerative = "generative" // A2UI generated from a skill, cached in the component registry
)

// Tool is the registry record of a tool: how its backend is reached and what
// its frontend is. Programs and skills are stored as bot entities (see the
// Entity* keys), not here.
type Tool struct {
	ID       string           `db:"id" json:"id"`
	BotID    string           `db:"bot_id" json:"bot_id"`
	Owner    string           `db:"owner" json:"owner"`
	URL      string           `db:"url" json:"url"`
	Auth     string           `db:"auth" json:"auth"`
	Commands []map[string]any `db:"commands" json:"commands"`
	Secrets  string           `db:"secrets" json:"-"`
	// Mode is the backend mode; empty on records made before modes existed,
	// which are external MCP servers.
	Mode string `db:"mode" json:"mode,omitempty"`
	// Runtime is what a managed or installed backend runs on.
	Runtime string `db:"runtime" json:"runtime,omitempty"`
	// Language is the source language of an Elpian VM backend (dart or js).
	Language string `db:"language" json:"language,omitempty"`
	// Image is the docker image of a docker backend.
	Image string `db:"image" json:"image,omitempty"`
	// Port is where a docker backend serves MCP (the runtime image's is fixed).
	Port int64 `db:"port" json:"port,omitempty"`
	// Endpoint is where a managed backend answers on the node's network.
	Endpoint string `db:"endpoint" json:"-"`
	// RuntimeKey names a managed or installed backend to the node: its
	// runtime credential is derived from it, and its service is named by it.
	RuntimeKey string `db:"runtime_key" json:"-"`
	// Frontend describes the tool's frontend (FrontendSpec as JSON).
	Frontend  string    `db:"frontend" json:"-"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

// EffectiveMode is the backend mode, treating records made before modes
// existed as external MCP servers.
func (t *Tool) EffectiveMode() string {
	if t.Mode == "" {
		return ModeExternal
	}
	return t.Mode
}

// FrontendSpec is what a tool shows people.
type FrontendSpec struct {
	// Mode is static, generative or empty (no frontend).
	Mode string `json:"mode,omitempty"`
	// Runtime and Language of a static frontend (elpian: dart or js; quickjs: js).
	Runtime  string `json:"runtime,omitempty"`
	Language string `json:"language,omitempty"`
	// Version changes whenever the frontend's program or skill changes, so a
	// generated frontend cached for an older one is not served again.
	Version string `json:"version,omitempty"`
	// Cache, for a generative frontend, keeps the first frontend generated
	// in the component registry and serves it to everyone after that. Off,
	// a frontend is generated for every request, designed for what the
	// person asked, following the skill. Unset means on.
	Cache *bool `json:"cache,omitempty"`
}

// Cached reports whether a generated frontend is kept and served again.
func (f FrontendSpec) Cached() bool { return f.Cache == nil || *f.Cache }

// Bot entity keys of a tool's programs.
const (
	EntityBackendSource    = "backend"           // backend program source (elpian/quickjs)
	EntityFrontendSource   = "frontend"          // static frontend program source
	EntityFrontendBytecode = "frontend_bytecode" // static Elpian frontend, compiled
	EntityFrontendSkill    = "frontend_skill"    // generative frontend skill / prompt
)

// Component is a generated frontend kept in the component registry: the A2UI
// surface generated once for a tool (and frontend version), served again for
// every later request and filled with fresh data each time.
type Component struct {
	ID    string `db:"id" json:"id"`
	BotID string `db:"bot_id" json:"bot_id"`
	// Key identifies what it was generated from (frontend version, skill and
	// the microtools it may call); a change of any of them makes a new one.
	Key string `db:"key" json:"key"`
	// Template is the generated frontend: A2UI components, the data bindings
	// that fill it and the actions it runs (Template as JSON).
	Template  string    `db:"template" json:"template"`
	Model     string    `db:"model" json:"model,omitempty"`
	Uses      int64     `db:"uses" json:"uses"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}
type Connection struct {
	ID        string     `db:"id" json:"id"`
	Owner     string     `db:"owner" json:"owner"`
	BotID     string     `db:"bot_id" json:"bot_id"`
	SpaceID   string     `db:"space_id" json:"space_id"`
	Secret    string     `db:"secret" json:"-"`
	ExpiresAt *time.Time `db:"expires_at" json:"expires_at,omitempty"`
	UpdatedAt time.Time  `db:"updated_at" json:"updated_at"`
}
type OAuth struct {
	ID        string    `db:"id"`
	Owner     string    `db:"owner"`
	Status    string    `db:"status"`
	Secret    string    `db:"secret" json:"-"`
	ExpiresAt time.Time `db:"expires_at"`
}

func Models() []database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return []database.Model{
		{Name: "tool_registry", Table: "tool_registry", Fields: []database.Field{f("id", database.KindString), f("bot_id", database.KindString), f("owner", database.KindString), f("url", database.KindString), f("auth", database.KindString), f("commands", database.KindJSON), f("secrets", database.KindString), f("mode", database.KindString), f("runtime", database.KindString), f("language", database.KindString), f("image", database.KindString), f("port", database.KindInt64), f("endpoint", database.KindString), f("runtime_key", database.KindString), f("frontend", database.KindString), f("updated_at", database.KindTime)}},
		{Name: "tool_components", Table: "tool_components", Fields: []database.Field{f("id", database.KindString), f("bot_id", database.KindString), f("key", database.KindString), f("template", database.KindString), f("model", database.KindString), f("uses", database.KindInt64), f("created_at", database.KindTime), f("updated_at", database.KindTime)}},
		{Name: "tool_connections", Table: "tool_connections", Fields: []database.Field{f("id", database.KindString), f("owner", database.KindString), f("bot_id", database.KindString), f("space_id", database.KindString), f("secret", database.KindString), f("expires_at", database.KindTime), f("updated_at", database.KindTime)}},
		{Name: "tool_oauth", Table: "tool_oauth", Fields: []database.Field{f("id", database.KindString), f("owner", database.KindString), f("status", database.KindString), f("secret", database.KindString), f("expires_at", database.KindTime)}},
	}
}
