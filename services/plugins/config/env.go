package dconfig

import (
	"math"
	"os"
	"strconv"
	"strings"

	modalconfig "github.com/tradera/tradera/plugins/adapters/vmm/modal/config"
)

// ModalConfig holds the Modal credentials used for the shared per-space agent
// sandboxes. It is the short form of the "modal" adapter plugin options.
type ModalConfig = modalconfig.ModalConfig

// Environment variables wiring the infrastructure. The docker compose setup
// sets them so the config file only carries node identity, Google sign-in and
// the Modal credentials.
const (
	EnvNodeName      = "TRADERA_NODE_NAME"
	EnvNodeURL       = "TRADERA_NODE_URL"
	EnvHTTPAddr      = "TRADERA_HTTP_ADDR"
	EnvDatabaseDSN   = "TRADERA_DATABASE_DSN" // postgres://...
	EnvNomadURL      = "TRADERA_NOMAD_URL"
	EnvDockerHost    = "TRADERA_DOCKER_HOST"
	EnvFilesDir      = "TRADERA_FILES_DIR"
	EnvWasmDir       = "TRADERA_WASM_DIR"
	EnvLogDir        = "TRADERA_LOG_DIR"
	EnvGoogleClient  = "TRADERA_GOOGLE_CLIENT_ID"
	EnvModalTokenID  = "TRADERA_MODAL_TOKEN_ID"
	EnvModalTokenSec = "TRADERA_MODAL_TOKEN_SECRET"
	// EnvModalEnvironment names the Modal environment (e.g. "dev") the sandboxes,
	// their volumes and their costs live in; empty uses the profile default.
	EnvModalEnvironment = "TRADERA_MODAL_ENVIRONMENT"
	// EnvSandboxBackend switches the shared per-space sandbox backbone
	// ("docker" | "modal"); EnvSandboxDockerNetwork attaches docker sandbox
	// containers to a network the node is on so proxied ports are reachable.
	EnvSandboxBackend       = "TRADERA_SANDBOX_BACKEND"
	EnvSandboxDockerNetwork = "TRADERA_SANDBOX_DOCKER_NETWORK"
	// EnvSandboxImage overrides the sandbox computer image (default: the
	// sandbox computer image).
	EnvSandboxImage    = "TRADERA_SANDBOX_IMAGE"
	EnvSandboxCPU      = "TRADERA_SANDBOX_CPU"
	EnvSandboxMemoryMB = "TRADERA_SANDBOX_MEMORY_MB"
	EnvSandboxDiskMB   = "TRADERA_SANDBOX_DISK_MB"
	// The deep agents runtime: the node URL as the runtime reaches it, the
	// runtime image Nomad runs, the docker network it joins, and an explicit
	// runtime URL (an externally run runtime; skips the Nomad job).
	EnvAgentNodeURL        = "TRADERA_AGENT_NODE_URL"
	EnvAgentRuntimeImage   = "TRADERA_AGENT_RUNTIME_IMAGE"
	EnvAgentRuntimeURL     = "TRADERA_AGENT_RUNTIME_URL"
	EnvAgentRuntimeNetwork = "TRADERA_AGENT_RUNTIME_NETWORK"
	EnvAgentRuntimeSecret  = "TRADERA_AGENT_RUNTIME_SECRET"
)

// ApplyEnv overlays the infrastructure environment variables onto the config.
// When the config lists no adapter plugins, the full adapter set is wired
// automatically (see AutoAdapters); otherwise the variables override the
// matching settings of the listed plugins.
func (c *Config) ApplyEnv() {
	if value := os.Getenv("TRADERA_PLUGIN_DIRECTORY"); value != "" {
		c.Plugins.Directory = value
	}
	if value := os.Getenv("TRADERA_PLUGIN_SOURCE_ROOT"); value != "" {
		c.Plugins.SourceRoot = value
	}
	overrides := []struct {
		name string
		set  func(int64)
	}{
		{EnvSandboxMemoryMB, func(v int64) { c.Sandbox.MemoryMB = v }},
		{EnvSandboxDiskMB, func(v int64) { c.Sandbox.DiskMB = v }},
	}
	if value, err := strconv.ParseFloat(os.Getenv(EnvSandboxCPU), 64); err == nil && value > 0 && !math.IsInf(value, 0) && !math.IsNaN(value) {
		c.Sandbox.CPU = value
	}
	for _, override := range overrides {
		if value, err := strconv.ParseInt(os.Getenv(override.name), 10, 64); err == nil && value > 0 {
			override.set(value)
		}
	}

	if v := os.Getenv(EnvNodeName); v != "" && c.Node.Name == "" {
		c.Node.Name = v
	}
	if v := os.Getenv(EnvNodeURL); v != "" {
		c.Node.URL = v
	}
	if v := os.Getenv(EnvHTTPAddr); v != "" {
		c.HTTP.Addr = v
	}
	if v := os.Getenv(EnvLogDir); v != "" {
		c.Logger.Dir = v
	}
	if c.Node.OAuthClientID == "" {
		if v := os.Getenv(EnvGoogleClient); v != "" {
			c.Node.OAuthClientID = v
		}
	}
	if v := os.Getenv(EnvModalTokenID); v != "" && c.Modal.TokenID == "" {
		c.Modal.TokenID = v
	}
	if v := os.Getenv(EnvModalTokenSec); v != "" && c.Modal.TokenSecret == "" {
		c.Modal.TokenSecret = v
	}
	if v := os.Getenv(EnvModalEnvironment); v != "" && c.Modal.Environment == "" {
		c.Modal.Environment = v
	}
	if v := os.Getenv(EnvSandboxBackend); v != "" {
		c.Sandbox.Backend = v
	}
	if v := os.Getenv(EnvSandboxDockerNetwork); v != "" {
		c.Sandbox.DockerNetwork = v
	}
	if v := os.Getenv(EnvSandboxImage); v != "" {
		c.Sandbox.Image = v
	}
	if len(c.Plugins.Adapters) == 0 {
		c.Plugins.Adapters = c.AutoAdapters()
		return
	}
	for i := range c.Plugins.Adapters {
		p := &c.Plugins.Adapters[i]
		switch p.Name {
		case "postgres":
			setIf(p, "dsn", os.Getenv(EnvDatabaseDSN))
		case "nomad":
			setIf(p, "nomad_url", os.Getenv(EnvNomadURL))
			setOption(p, "docker_host", os.Getenv(EnvDockerHost))
		case "docker":
			setOption(p, "host", os.Getenv(EnvDockerHost))
			setOption(p, "network", os.Getenv(EnvSandboxDockerNetwork))
		case "deepagents":
			setOption(p, "node_url", os.Getenv(EnvAgentNodeURL))
			setOption(p, "image", os.Getenv(EnvAgentRuntimeImage))
			setOption(p, "runtime_url", os.Getenv(EnvAgentRuntimeURL))
			setOption(p, "network", envOr(EnvAgentRuntimeNetwork, os.Getenv(EnvSandboxDockerNetwork)))
			setOption(p, "runtime_secret", os.Getenv(EnvAgentRuntimeSecret))
		case "http":
			setIf(p, "addr", os.Getenv(EnvHTTPAddr))
		case "local":
			setIf(p, "base_path", os.Getenv(EnvFilesDir))
		case "wasm":
			setOption(p, "module_root", os.Getenv(EnvWasmDir))
		case "modal":
			setOption(p, "modal_token_id", c.Modal.TokenID)
			setOption(p, "modal_token_secret", c.Modal.TokenSecret)
			if c.Modal.Environment != "" {
				setOption(p, "modal_environment", c.Modal.Environment)
			}
		}
	}
}

// AutoAdapters builds the adapter plugin set from the environment: postgres
// when a DSN is given (in-memory otherwise), the local cache and filesystem,
// HTTP, the nomad and docker VMM providers when reachable, the deep agents
// runtime (LLM providers are managed in the admin panel),
// Modal sandboxes when credentials are set, and wasm miniapp backends.
func (c *Config) AutoAdapters() []PluginSpec {
	var out []PluginSpec
	add := func(name string, cfg map[string]any) {
		out = append(out, PluginSpec{Name: name, Enabled: true, Config: cfg})
	}
	if dsn := os.Getenv(EnvDatabaseDSN); dsn != "" {
		add("postgres", map[string]any{"dsn": dsn})
	} else {
		add("memory", nil)
	}
	add("local-cache", nil)
	add("local", map[string]any{"base_path": envOr(EnvFilesDir, "./data/files")})
	addr := c.HTTP.Addr
	if addr == "" {
		addr = ":8080"
	}
	add("http", map[string]any{"addr": addr})
	if u := os.Getenv(EnvNomadURL); u != "" {
		nomad := map[string]any{"nomad_url": u}
		// The nomad provider execs into its docker allocations directly.
		if h := os.Getenv(EnvDockerHost); h != "" {
			nomad["options"] = map[string]any{"docker_host": h}
		}
		add("nomad", nomad)
	}
	if h := os.Getenv(EnvDockerHost); h != "" {
		opts := map[string]any{"host": h}
		if n := os.Getenv(EnvSandboxDockerNetwork); n != "" {
			opts["network"] = n
		}
		add("docker", map[string]any{"options": opts})
	}
	add("mcp", nil)
	// Every agent runs on the deep agents runtime: a Python service the node
	// supervises as a Nomad job. It reaches the node back at the agent node URL.
	agentOpts := map[string]any{}
	for key, env := range map[string]string{"node_url": EnvAgentNodeURL, "image": EnvAgentRuntimeImage, "runtime_url": EnvAgentRuntimeURL, "network": EnvAgentRuntimeNetwork, "runtime_secret": EnvAgentRuntimeSecret} {
		if v := os.Getenv(env); v != "" {
			agentOpts[key] = v
		}
	}
	if _, ok := agentOpts["network"]; !ok {
		if n := os.Getenv(EnvSandboxDockerNetwork); n != "" {
			agentOpts["network"] = n
		}
	}
	add("deepagents", map[string]any{"options": agentOpts})
	if c.Modal.TokenID != "" && c.Modal.TokenSecret != "" {
		opts := map[string]any{"modal_token_id": c.Modal.TokenID, "modal_token_secret": c.Modal.TokenSecret}
		if c.Modal.Environment != "" {
			opts["modal_environment"] = c.Modal.Environment
		}
		add("modal", map[string]any{"options": opts})
	}
	add("wasm", map[string]any{"options": map[string]any{"module_root": envOr(EnvWasmDir, "./data/wasm")}})
	return out
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func setIf(p *PluginSpec, key, value string) {
	if value == "" {
		return
	}
	if p.Config == nil {
		p.Config = map[string]any{}
	}
	p.Config[key] = value
}

func setOption(p *PluginSpec, key, value string) {
	if value == "" {
		return
	}
	if p.Config == nil {
		p.Config = map[string]any{}
	}
	opts, _ := p.Config["options"].(map[string]any)
	if opts == nil {
		opts = map[string]any{}
	}
	if _, set := opts[key]; set && (key == "modal_token_id" || key == "modal_token_secret" || key == "modal_environment") {
		return // explicit plugin options win over the short modal section
	}
	opts[key] = value
	p.Config["options"] = opts
}
