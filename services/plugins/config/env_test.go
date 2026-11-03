package dconfig

import (
	"os"
	"path/filepath"
	"testing"
)

func names(specs []PluginSpec) map[string]PluginSpec {
	out := map[string]PluginSpec{}
	for _, s := range specs {
		out[s.Name] = s
	}
	return out
}

func TestMinimalConfigAutoWiresFromEnv(t *testing.T) {
	t.Setenv(EnvDatabaseDSN, "postgres://u:p@db:5432/d?sslmode=disable")
	t.Setenv(EnvNomadURL, "http://nomad:4646")
	t.Setenv(EnvDockerHost, "unix:///var/run/docker.sock")
	t.Setenv(EnvNodeURL, "http://example.test:8080")
	path := filepath.Join(t.TempDir(), "config.yml")
	yml := "node:\n  name: node-a\n  oauth_client_id: google-123\nmodal:\n  token_id: ak-1\n  token_secret: as-2\n"
	if err := os.WriteFile(path, []byte(yml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	got := names(cfg.Plugins.Adapters)
	for _, n := range []string{"postgres", "local-cache", "local", "http", "nomad", "docker", "harness", "modal", "wasm"} {
		if _, ok := got[n]; !ok {
			t.Errorf("adapter %s not wired", n)
		}
	}
	if _, ok := got["memory"]; ok {
		t.Error("memory db must not be wired when a DSN is set")
	}
	if got["postgres"].Config["dsn"] != "postgres://u:p@db:5432/d?sslmode=disable" {
		t.Errorf("dsn = %v", got["postgres"].Config["dsn"])
	}
	opts := got["modal"].Config["options"].(map[string]any)
	if opts["modal_token_id"] != "ak-1" || opts["modal_token_secret"] != "as-2" {
		t.Errorf("modal options = %v", opts)
	}
	if !cfg.Node.Central || cfg.Node.URL != "http://example.test:8080" || cfg.Node.OAuthClientID != "google-123" {
		t.Errorf("node = %+v", cfg.Node)
	}
}

func TestAnS3BucketReplacesTheLocalFilesystem(t *testing.T) {
	for _, k := range []string{EnvDatabaseDSN, EnvNomadURL, EnvDockerHost, EnvModalTokenID, EnvModalTokenSec} {
		t.Setenv(k, "")
	}
	t.Setenv(EnvS3Bucket, "files")
	t.Setenv(EnvS3Endpoint, "https://acct.r2.cloudflarestorage.com")
	t.Setenv(EnvS3AccessKey, "id")
	t.Setenv(EnvS3SecretKey, "secret")
	cfg := &Config{}
	cfg.ApplyEnv()
	cfg.Defaults()
	got := names(cfg.Plugins.Adapters)
	if _, ok := got["local"]; ok {
		t.Fatal("the node's disk is not used for files when a bucket is set")
	}
	s3 := got["s3"].Config
	opts, _ := s3["options"].(map[string]any)
	if s3["bucket"] != "files" || s3["endpoint"] != "https://acct.r2.cloudflarestorage.com" || s3["region"] != "auto" || opts["access_key_id"] != "id" || opts["secret_access_key"] != "secret" {
		t.Fatalf("s3 = %v", s3)
	}
}

func TestAutoWiringWithoutEnvUsesMemoryAndSkipsOptional(t *testing.T) {
	for _, k := range []string{EnvDatabaseDSN, EnvNomadURL, EnvDockerHost, EnvModalTokenID, EnvModalTokenSec} {
		t.Setenv(k, "")
	}
	cfg := &Config{}
	cfg.ApplyEnv()
	cfg.Defaults()
	got := names(cfg.Plugins.Adapters)
	if _, ok := got["memory"]; !ok {
		t.Error("memory db expected without a DSN")
	}
	for _, n := range []string{"nomad", "docker", "modal", "postgres"} {
		if _, ok := got[n]; ok {
			t.Errorf("%s must not be wired without its settings", n)
		}
	}
	if got["http"].Config["addr"] != ":8080" || cfg.Node.Name != "admin" {
		t.Errorf("defaults: http=%v name=%q", got["http"].Config, cfg.Node.Name)
	}
}

func TestEnvOverridesExplicitPlugins(t *testing.T) {
	t.Setenv(EnvDatabaseDSN, "postgres://override")
	cfg := &Config{Modal: ModalConfig{TokenID: "a", TokenSecret: "b"}, Plugins: PluginsConfig{Adapters: []PluginSpec{
		{Name: "postgres", Enabled: true, Config: map[string]any{"dsn": "postgres://file"}},
		{Name: "modal", Enabled: true},
	}}}
	cfg.ApplyEnv()
	got := names(cfg.Plugins.Adapters)
	if got["postgres"].Config["dsn"] != "postgres://override" {
		t.Errorf("dsn not overridden: %v", got["postgres"].Config)
	}
	if got["modal"].Config["options"].(map[string]any)["modal_token_id"] != "a" {
		t.Errorf("modal short form not applied: %v", got["modal"].Config)
	}
}

func TestSandboxBackendConfig(t *testing.T) {
	// Defaults to a docker container per space.
	cfg := &Config{}
	cfg.Defaults()
	if cfg.Sandbox.Backend != "docker" {
		t.Fatalf("default sandbox backend = %q, want docker", cfg.Sandbox.Backend)
	}
	// Env switches the backend and wires the docker network into the adapter.
	t.Setenv(EnvSandboxBackend, "modal")
	t.Setenv(EnvSandboxDockerNetwork, "mynet")
	t.Setenv(EnvDockerHost, "unix:///var/run/docker.sock")
	cfg = &Config{}
	cfg.ApplyEnv()
	cfg.Defaults()
	if cfg.Sandbox.Backend != "modal" {
		t.Errorf("sandbox backend = %q, want modal", cfg.Sandbox.Backend)
	}
	if cfg.Sandbox.DockerNetwork != "mynet" {
		t.Errorf("sandbox docker_network = %q, want mynet", cfg.Sandbox.DockerNetwork)
	}
	got := names(cfg.Plugins.Adapters)
	opts, ok := got["docker"].Config["options"].(map[string]any)
	if !ok || opts["host"] == "" || opts["network"] != "mynet" {
		t.Errorf("docker adapter options = %v, want host+network wired", got["docker"].Config)
	}
}

func TestAgentRuntimeWiredFromEnv(t *testing.T) {
	t.Setenv(EnvAgentNodeURL, "http://aseman:8080")
	t.Setenv(EnvAgentRuntimeImage, "aseman/harness:test")
	t.Setenv(EnvSandboxDockerNetwork, "aseman_default")
	cfg := &Config{}
	got := names(cfg.AutoAdapters())
	opts, ok := got["harness"].Config["options"].(map[string]any)
	if !ok || opts["node_url"] != "http://aseman:8080" || opts["image"] != "aseman/harness:test" || opts["network"] != "aseman_default" {
		t.Fatalf("harness options = %v", got["harness"].Config)
	}
	for _, removed := range []string{"langchain", "grok"} {
		if _, ok := got[removed]; ok {
			t.Fatalf("%s adapter still wired", removed)
		}
	}
}

func TestModalEnvironmentReachesAdapter(t *testing.T) {
	t.Setenv(EnvModalEnvironment, "dev")
	cfg := &Config{Modal: ModalConfig{TokenID: "a", TokenSecret: "b"}, Plugins: PluginsConfig{Adapters: []PluginSpec{
		{Name: "modal", Enabled: true},
	}}}
	cfg.ApplyEnv()
	if got := names(cfg.Plugins.Adapters)["modal"].Config["options"].(map[string]any)["modal_environment"]; got != "dev" {
		t.Errorf("modal_environment = %v, want dev", got)
	}
}
