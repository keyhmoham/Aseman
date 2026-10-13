// Package dconfig loads and exposes tradera's runtime configuration. Config
// may be JSON or YAML; the file layout is deterministic and fully mapped to
// typed structs (no magic keys except inside plugin config maps).
package dconfig

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	spacesconfig "github.com/tradera/tradera/plugins/actions/spaces/config"

	"gopkg.in/yaml.v3"
)

// Config is the root configuration.
type Config struct {
	Node   NodeConfig   `json:"node" yaml:"node"`
	Logger LoggerConfig `json:"logger" yaml:"logger"`
	HTTP   HTTPConfig   `json:"http" yaml:"http"`
	// Modal holds the Modal sandbox credentials (short form; wired into the
	// modal adapter automatically).
	Modal ModalConfig `json:"modal" yaml:"modal"`
	// Sandbox selects the shared per-space sandbox backbone.
	Sandbox  SandboxConfig  `json:"sandbox" yaml:"sandbox"`
	Plugins  PluginsConfig  `json:"plugins" yaml:"plugins"`
	Adapters AdaptersConfig `json:"adapters" yaml:"adapters"`
	Actions  ActionsConfig  `json:"actions" yaml:"actions"`
}

// SandboxConfig selects the shared per-space sandbox backbone. One variable
// switches the whole stack between a docker container per space and a Modal
// remote sandbox per space.
type SandboxConfig = spacesconfig.SandboxConfig

// DefaultSandboxImage is the sandbox computer image (deploy/sandbox-computer):
// the shared per-space machine (shell, filesystem and a development toolchain)
// every agent of a space works on.
const DefaultSandboxImage = "tradera/sandbox-computer:latest"

// NodeConfig identifies this federation node.
type NodeConfig struct {
	ID            string `json:"id" yaml:"id"` // 16-hex node id; empty => bootstrap
	Name          string `json:"name" yaml:"name"`
	URL           string `json:"url" yaml:"url"`
	Central       bool   `json:"central" yaml:"central"`
	CentralURL    string `json:"central_url" yaml:"central_url"` // central node URL (used to bootstrap an id)
	PublicKey     string `json:"public_key" yaml:"public_key"`
	PrivateKey    string `json:"private_key" yaml:"private_key"` // hex; auto-generated when empty
	OAuthClientID string `json:"oauth_client_id" yaml:"oauth_client_id"`
}

// LoggerConfig configures logging.
type LoggerConfig struct {
	Level string `json:"level" yaml:"level"`
	JSON  bool   `json:"json" yaml:"json"`
	// Dir is the per-plugin log directory (empty disables per-plugin files).
	Dir string `json:"dir" yaml:"dir"`
}

// HTTPConfig configures the HTTP driving adapter.
type HTTPConfig struct {
	Addr string `json:"addr" yaml:"addr"`
}

// PluginsConfig lists plugins to load at boot.
type PluginsConfig struct {
	Directory  string       `json:"directory,omitempty" yaml:"directory,omitempty"`
	SourceRoot string       `json:"source_root,omitempty" yaml:"source_root,omitempty"`
	Adapters   []PluginSpec `json:"adapters" yaml:"adapters"`
	Actions    []PluginSpec `json:"actions" yaml:"actions"`
	Modules    []PluginSpec `json:"modules" yaml:"modules"`
}

// PluginSpec describes one plugin to load.
type PluginSpec struct {
	Name    string         `json:"name" yaml:"name"`
	Source  string         `json:"source,omitempty" yaml:"source,omitempty"` // empty => bin/plugins/<layer>/<name>.so
	Enabled bool           `json:"enabled" yaml:"enabled"`
	Config  map[string]any `json:"config,omitempty" yaml:"config,omitempty"`
}

// AdaptersConfig selects the active adapter per category and provides settings.
type AdaptersConfig struct {
	Database map[string]any `json:"database" yaml:"database"`
	Cache    map[string]any `json:"cache" yaml:"cache"`
	Network  map[string]any `json:"network" yaml:"network"`
	Storage  map[string]any `json:"storage" yaml:"storage"`
	VMM      map[string]any `json:"vmm" yaml:"vmm"`
}

// ActionsConfig controls which namespaces are enabled at boot.
type ActionsConfig struct {
	Enabled []string `json:"enabled" yaml:"enabled"`
}

// Provider exposes typed config access.
type Provider struct {
	cfg *Config
}

// Load reads and parses a config file (JSON or YAML by extension).
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".yaml", ".yml":
		if err := yaml.Unmarshal(b, cfg); err != nil {
			return nil, err
		}
	default:
		if err := json.Unmarshal(b, cfg); err != nil {
			return nil, err
		}
	}
	cfg.ApplyEnv()
	cfg.Defaults()
	return cfg, nil
}

// Defaults fills in sensible defaults. An empty node.id is intentionally kept
// empty so first-run nodes bootstrap an id from the central node.
func (c *Config) Defaults() {
	if c.Logger.Level == "" {
		c.Logger.Level = "info"
	}
	if c.Logger.Dir == "" {
		c.Logger.Dir = "data/logs"
	}
	if c.HTTP.Addr == "" {
		c.HTTP.Addr = ":8080"
	}
	if c.Node.Name == "" {
		c.Node.Name = "admin"
	}
	if c.Node.URL == "" {
		c.Node.URL = "http://localhost" + c.HTTP.Addr
	}
	// A node with no central node to join is its own central node.
	if !c.Node.Central && c.Node.CentralURL == "" {
		c.Node.Central = true
	}
	// The shared per-space sandbox backbone defaults to a docker container per
	// space; switch to Modal with "sandbox.backend: modal".
	if c.Sandbox.Backend == "" {
		c.Sandbox.Backend = "docker"
	}
	if c.Sandbox.CPU <= 0 {
		c.Sandbox.CPU = 2
	}
	if c.Sandbox.MemoryMB <= 0 {
		c.Sandbox.MemoryMB = 2048
	}
	if c.Sandbox.DiskMB <= 0 {
		c.Sandbox.DiskMB = 4096
	}
	if c.Sandbox.Image == "" {
		c.Sandbox.Image = DefaultSandboxImage
	}
}

// NewProvider wraps a parsed config.
func NewProvider(cfg *Config) *Provider { return &Provider{cfg: cfg} }

// Get returns the root config.
func (p *Provider) Get() *Config { return p.cfg }

// PluginConfig returns the map config for a plugin name or an empty map.
func (p *Provider) PluginConfig(name string) map[string]any {
	for _, spec := range p.cfg.Plugins.Adapters {
		if spec.Name == name && spec.Config != nil {
			return spec.Config
		}
	}
	for _, spec := range p.cfg.Plugins.Actions {
		if spec.Name == name && spec.Config != nil {
			return spec.Config
		}
	}
	for _, spec := range p.cfg.Plugins.Modules {
		if spec.Name == name && spec.Config != nil {
			return spec.Config
		}
	}
	return map[string]any{}
}

// AdapterConfig returns the category adapter settings map.
func (p *Provider) AdapterConfig(category string) map[string]any {
	switch category {
	case "database":
		return p.cfg.Adapters.Database
	case "cache":
		return p.cfg.Adapters.Cache
	case "network":
		return p.cfg.Adapters.Network
	case "storage":
		return p.cfg.Adapters.Storage
	case "vmm":
		return p.cfg.Adapters.VMM
	}
	return nil
}
