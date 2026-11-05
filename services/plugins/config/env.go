package dconfig

import (
	"math"
	"os"
	"strconv"
	"strings"

	modalconfig "github.com/aseman/aseman/plugins/adapters/vmm/modal/config"
)

// ModalConfig holds the Modal credentials used for the shared per-space agent
// sandboxes. It is the short form of the "modal" adapter plugin options.
type ModalConfig = modalconfig.ModalConfig

// Environment variables wiring the infrastructure. The docker compose setup
// sets them so the config file only carries node identity, Google sign-in and
// the Modal credentials.
const (
	EnvNodeName = "ASEMAN_NODE_NAME"
	EnvNodeURL  = "ASEMAN_NODE_URL"
	EnvHTTPAddr = "ASEMAN_HTTP_ADDR"
	// EnvDeveloperHost is the host of the developer API (api.example.com):
	// the node serves only the developer routes on it, and its /v1/... is that
	// API. Empty: the developer API is not exposed on its own host.
	EnvDeveloperHost = "ASEMAN_DEVELOPER_HOST"
	EnvDatabaseDSN   = "ASEMAN_DATABASE_DSN" // postgres://...
	EnvNomadURL      = "ASEMAN_NOMAD_URL"
	EnvDockerHost    = "ASEMAN_DOCKER_HOST"
	EnvFilesDir      = "ASEMAN_FILES_DIR"
	// The node's files (attachments, developer storage) go to an S3-compatible
	// bucket (Cloudflare R2, AWS S3, MinIO) instead of the node's disk when a
	// bucket is set. The endpoint is the store's S3 API address (for R2:
	// https://<account>.r2.cloudflarestorage.com); the region is "auto" for R2.
	EnvS3Bucket      = "ASEMAN_S3_BUCKET"
	EnvS3Endpoint    = "ASEMAN_S3_ENDPOINT"
	EnvS3Region      = "ASEMAN_S3_REGION"
	EnvS3AccessKey   = "ASEMAN_S3_ACCESS_KEY_ID"
	EnvS3SecretKey   = "ASEMAN_S3_SECRET_ACCESS_KEY"
	EnvWasmDir       = "ASEMAN_WASM_DIR"
	EnvLogDir        = "ASEMAN_LOG_DIR"
	EnvGoogleClient  = "ASEMAN_GOOGLE_CLIENT_ID"
	EnvModalTokenID  = "ASEMAN_MODAL_TOKEN_ID"
	EnvModalTokenSec = "ASEMAN_MODAL_TOKEN_SECRET"
	// EnvModalEnvironment names the Modal environment (e.g. "dev") the sandboxes,
	// their volumes and their costs live in; empty uses the profile default.
	EnvModalEnvironment = "ASEMAN_MODAL_ENVIRONMENT"
	// EnvSandboxBackend switches the shared per-space sandbox backbone
	// ("docker" | "modal"); EnvSandboxDockerNetwork attaches docker sandbox
	// containers to a network the node is on so proxied ports are reachable.
	EnvSandboxBackend       = "ASEMAN_SANDBOX_BACKEND"
	EnvSandboxDockerNetwork = "ASEMAN_SANDBOX_DOCKER_NETWORK"
	// EnvSandboxImage overrides the sandbox computer image (default: the
	// sandbox computer image).
	EnvSandboxImage    = "ASEMAN_SANDBOX_IMAGE"
	EnvSandboxCPU      = "ASEMAN_SANDBOX_CPU"
	EnvSandboxMemoryMB = "ASEMAN_SANDBOX_MEMORY_MB"
	EnvSandboxDiskMB   = "ASEMAN_SANDBOX_DISK_MB"
	// The deep agents runtime: the node URL as the runtime reaches it, the
	// runtime image Nomad runs, the docker network it joins, and an explicit
	// runtime URL (an externally run runtime; skips the Nomad job).
	EnvAgentNodeURL        = "ASEMAN_AGENT_NODE_URL"
	EnvAgentRuntimeImage   = "ASEMAN_AGENT_RUNTIME_IMAGE"
	EnvAgentRuntimeURL     = "ASEMAN_AGENT_RUNTIME_URL"
	EnvAgentRuntimeNetwork = "ASEMAN_AGENT_RUNTIME_NETWORK"
	EnvAgentRuntimeSecret  = "ASEMAN_AGENT_RUNTIME_SECRET"
	// EnvToolRuntimeImage is the image Nomad runs managed Elpian VM and QuickJS
	// tool backends in (default aseman/tool-runtime:v1).
	EnvToolRuntimeImage = "ASEMAN_TOOL_RUNTIME_IMAGE"
)

// ApplyEnv overlays the infrastructure environment variables onto the config.
// When the config lists no adapter plugins, the full adapter set is wired
// automatically (see AutoAdapters); otherwise the variables override the
// matching settings of the listed plugins.
func (c *Config) ApplyEnv() {
	if value := os.Getenv("ASEMAN_PLUGIN_DIRECTORY"); value != "" {
		c.Plugins.Directory = value
	}
	if value := os.Getenv("ASEMAN_PLUGIN_SOURCE_ROOT"); value != "" {
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
		// The agent runtime was the "deepagents" plugin before DeepSeek Harness.
		if p.Name == "deepagents" {
			p.Name = "harness"
		}
		switch p.Name {
		case "postgres":
			setIf(p, "dsn", os.Getenv(EnvDatabaseDSN))
		case "nomad":
			setIf(p, "nomad_url", os.Getenv(EnvNomadURL))
			setOption(p, "docker_host", os.Getenv(EnvDockerHost))
			setOption(p, "tool_runtime_image", os.Getenv(EnvToolRuntimeImage))
		case "docker":
			setOption(p, "host", os.Getenv(EnvDockerHost))
			setOption(p, "network", os.Getenv(EnvSandboxDockerNetwork))
		case "harness":
			setOption(p, "node_url", os.Getenv(EnvAgentNodeURL))
			setOption(p, "image", os.Getenv(EnvAgentRuntimeImage))
			setOption(p, "runtime_url", os.Getenv(EnvAgentRuntimeURL))
			setOption(p, "network", envOr(EnvAgentRuntimeNetwork, os.Getenv(EnvSandboxDockerNetwork)))
			setOption(p, "runtime_secret", os.Getenv(EnvAgentRuntimeSecret))
		case "http":
			setIf(p, "addr", os.Getenv(EnvHTTPAddr))
			setOption(p, "developer_host", os.Getenv(EnvDeveloperHost))
		case "local":
			setIf(p, "base_path", os.Getenv(EnvFilesDir))
		case "s3":
			for key, env := range map[string]string{"bucket": EnvS3Bucket, "endpoint": EnvS3Endpoint, "region": EnvS3Region} {
				setIf(p, key, os.Getenv(env))
			}
			setOption(p, "access_key_id", os.Getenv(EnvS3AccessKey))
			setOption(p, "secret_access_key", os.Getenv(EnvS3SecretKey))
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
// HTTP, the nomad and docker VMM providers when reachable, the Harness agent
// runtime (LLM providers are managed in the admin panel),
// Modal sandboxes when credentials are set, and wasm app backends.
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
	if bucket := os.Getenv(EnvS3Bucket); bucket != "" {
		region := envOr(EnvS3Region, "auto")
		add("s3", map[string]any{"bucket": bucket, "endpoint": os.Getenv(EnvS3Endpoint), "region": region,
			"options": map[string]any{"access_key_id": os.Getenv(EnvS3AccessKey), "secret_access_key": os.Getenv(EnvS3SecretKey)}})
	} else {
		add("local", map[string]any{"base_path": envOr(EnvFilesDir, "./data/files")})
	}
	addr := c.HTTP.Addr
	if addr == "" {
		addr = ":8080"
	}
	httpConfig := map[string]any{"addr": addr}
	if host := os.Getenv(EnvDeveloperHost); host != "" {
		httpConfig["options"] = map[string]any{"developer_host": host}
	}
	add("http", httpConfig)
	if u := os.Getenv(EnvNomadURL); u != "" {
		nomad := map[string]any{"nomad_url": u}
		options := map[string]any{}
		// The nomad provider execs into its docker allocations directly.
		if h := os.Getenv(EnvDockerHost); h != "" {
			options["docker_host"] = h
		}
		if img := os.Getenv(EnvToolRuntimeImage); img != "" {
			options["tool_runtime_image"] = img
		}
		if len(options) > 0 {
			nomad["options"] = options
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
	add("harness", map[string]any{"options": agentOpts})
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
