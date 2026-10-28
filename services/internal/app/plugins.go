package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/host"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/logs"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/config"
)

var defaultNamespaces = []string{"auth", "users", "finance", "federation", "llm", "usage", "developer", "bots", "message", "posts", "market", "spaces", "routines", "settings", "talent", "tools", "timeline", "governance", "google", "proactive", "responsibilities", "channels", "enterprise", "admin"}

func bootPlugins(cfg *dconfig.Config, k *kernel.Kernel, ring *logs.Ring) error {
	root, directory, err := pluginPaths(cfg)
	if err != nil {
		return err
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	var global map[string]any
	if err := json.Unmarshal(raw, &global); err != nil {
		return err
	}
	k.ConfigurePlugins(global, root, directory)
	k.Provide("logs", ring)
	load := func(spec dconfig.PluginSpec, layer string) error {
		if !spec.Enabled {
			return nil
		}
		source := spec.Source
		if source == "" {
			source = filepath.Join(directory, layer, spec.Name+".so")
		}
		if !filepath.IsAbs(source) {
			source = filepath.Join(root, source)
		}
		info, err := k.LoadPlugin(context.Background(), source, spec.Config)
		if err != nil {
			return errs.Wrap(errs.CodePlugin, err, "load "+spec.Name+" (build native plugins with make plugins)")
		}
		if info.Name != spec.Name {
			return errs.New(errs.CodePlugin, "plugin name differs from configured name: "+spec.Name)
		}
		return nil
	}
	for _, spec := range cfg.Plugins.Adapters {
		if err := load(spec, "adapters"); err != nil {
			return err
		}
	}
	specs := actionSpecs(cfg)
	for _, spec := range specs {
		if err := load(spec, "actions"); err != nil {
			return err
		}
	}
	for _, spec := range cfg.Plugins.Modules {
		if err := load(spec, "modules"); err != nil {
			return err
		}
	}
	return nil
}

func pluginPaths(cfg *dconfig.Config) (string, string, error) {
	root := cfg.Plugins.SourceRoot
	if root == "" {
		root = "."
		if _, err := os.Stat("go.mod"); err != nil {
			root = "services"
		}
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return "", "", err
	}
	directory := cfg.Plugins.Directory
	if directory == "" {
		directory = filepath.Join(root, "bin", "plugins")
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		return "", "", err
	}
	return root, directory, nil
}
func actionSpecs(cfg *dconfig.Config) []dconfig.PluginSpec {
	specs := cfg.Plugins.Actions
	if len(specs) == 0 {
		for _, namespace := range defaultNamespaces {
			enabled := len(cfg.Actions.Enabled) == 0
			for _, name := range cfg.Actions.Enabled {
				if name == namespace || name == namespace+"-ns" {
					enabled = true
				}
			}

			specs = append(specs, dconfig.PluginSpec{Name: namespace + "-ns", Enabled: enabled})
		}
	}
	return specs
}

// prepareIdentity invokes a native plugin's optional preflight hook without
// importing its implementation into the fixed host.
func prepareIdentity(cfg *dconfig.Config, log *logger.Logger) (api.NodeIdentity, error) {
	root, directory, err := pluginPaths(cfg)
	if err != nil {
		return api.NodeIdentity{}, err
	}
	data, err := json.Marshal(cfg)
	if err != nil {
		return api.NodeIdentity{}, err
	}
	var config map[string]any
	if err = json.Unmarshal(data, &config); err != nil {
		return api.NodeIdentity{}, err
	}
	loader := host.NewLoader(log)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, spec := range actionSpecs(cfg) {
		if !spec.Enabled {
			continue
		}
		source := spec.Source
		if source == "" {
			source = filepath.Join(directory, "actions", spec.Name+".so")
		}
		if !filepath.IsAbs(source) {
			source = filepath.Join(root, source)
		}
		plugin, err := loader.Load(source)
		if err != nil {
			return api.NodeIdentity{}, err
		}
		if plugin.Info().Name != spec.Name {
			return api.NodeIdentity{}, errs.InvalidArgument("plugin name differs from configured name: " + spec.Name)
		}
		if provider, ok := plugin.(api.IdentityProvisioner); ok {
			prepared, err := provider.PrepareIdentity(ctx, config, log)
			if err != nil {
				return api.NodeIdentity{}, err
			}
			cfg.Node.ID = prepared.ID
			cfg.Node.PublicKey = prepared.PublicKey
			return prepared, nil
		}
	}
	local, err := identity.Local(cfg.Node.ID, cfg.Node.PrivateKey)
	if err != nil {
		return api.NodeIdentity{}, err
	}
	cfg.Node.ID = local.ID
	cfg.Node.PublicKey = local.PublicKey
	return api.NodeIdentity{ID: local.ID, PrivateKey: local.PrivateKey, PublicKey: local.PublicKey}, nil
}
