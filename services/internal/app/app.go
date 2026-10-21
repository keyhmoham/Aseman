// Package app is the composition root of the aseman daemon. It builds the
// kernel, registers the builtin adapter and action plugins, loads configured
// plugins, registers the default database models and starts the network
// serving the action API.
package app

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/logs"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/network/gateway"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/config"
)

// App is a running aseman node.
type App struct {
	K    *kernel.Kernel
	Ring *logs.Ring
	Log  *logger.Logger
	API  *apihttp.API
}

// New assembles and boots the application.
func New(cfg *dconfig.Config, extraEnv map[string]string) (*App, error) {
	ring := logs.NewRing(2000)
	opts := &slog.HandlerOptions{Level: logger.Level(cfg.Logger.Level)}
	multi := logger.NewMulti(
		slog.NewTextHandler(os.Stderr, opts),
		logs.NewHandler(ring),
	)
	log := multi.Named("aseman")
	logger.SetGlobal(log)

	prepared, err := prepareIdentity(cfg, log)
	nodeIDStr, nodePriv, nodePub := prepared.ID, prepared.PrivateKey, prepared.PublicKey
	if err != nil {
		return nil, err
	}
	if cfg.Node.PublicKey == "" {
		cfg.Node.PublicKey = nodePub
	}

	env := map[string]string{
		"central":          "false",
		"node_url":         cfg.Node.URL,
		"admin_handle":     cfg.Node.Name,
		"node_private_key": nodePriv,
		"node_public_key":  nodePub,
		"google_client_id": cfg.Node.OAuthClientID,
	}
	for key, value := range prepared.Env {
		env[key] = value
	}

	if cfg.Node.Central {
		env["central"] = "true"
	}
	for k, v := range extraEnv {
		env[k] = v
	}

	nodeID, err := parseNodeID(nodeIDStr)
	if err != nil {
		return nil, err
	}

	k := kernel.New(kernel.Options{
		NodeID: nodeID,
		Config: dconfig.NewProvider(cfg),
		Logger: log,
		Env:    env,
		LogDir: cfg.Logger.Dir,
	})

	if err := bootPlugins(cfg, k, ring); err != nil {
		_ = k.Shutdown(context.Background())
		return nil, err
	}
	app := &App{K: k, Ring: ring, Log: log}
	app.API = apihttp.NewHost(k, log)
	binder := func(net network.Network) error {
		if err := app.API.Register(net); err != nil {
			return err
		}
		return nil
	}
	k.SetNetworkBinder(binder)
	if net := k.Network(); net != nil {
		if err := binder(net); err != nil {
			return nil, err
		}
	}

	return app, nil
}

// Serve starts the active network adapter (blocking).
// Serve supervises the selected protocol provider across runtime wiring changes.
func (a *App) Serve(ctx context.Context) error {
	for {
		version := a.K.NetworkVersion()
		net := a.K.Network()
		if net == nil {
			select {
			case <-ctx.Done():
				return nil
			case <-a.K.NetworkChanges():
				continue
			}
		}
		if a.K.NetworkVersion() != version {
			continue
		}
		serveCtx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() { done <- net.Serve(serveCtx) }()
		switchProvider := false
		for !switchProvider {
			select {
			case <-ctx.Done():
				switchProvider = true
			case <-a.K.NetworkChanges():
				switchProvider = a.K.NetworkVersion() != version
			case err := <-done:
				cancel()
				if ctx.Err() != nil {
					return nil
				}
				if err != nil && a.K.NetworkVersion() == version {
					return err
				}
				done = nil
				// A clean listener exit may precede the manager's state transition.
				// Wait for that transition rather than ending the node's supervisor.
				switchProvider = a.K.NetworkVersion() != version
			}
		}
		cancel()
		closeCtx, finish := context.WithTimeout(context.Background(), 30*time.Second)
		_ = net.Close(closeCtx)
		if done != nil {
			select {
			case <-done:
			case <-closeCtx.Done():
				finish()
				return closeCtx.Err()
			}
		}
		finish()
		if ctx.Err() != nil {
			return nil
		}
	}
}

// Bootstrap runs plugin-owned initialization after all namespaces have started.
func (a *App) Bootstrap(ctx context.Context) error {
	for _, entry := range a.K.Registry().List() {
		if entry.State != api.StateStarted {
			continue
		}
		if plugin, ok := entry.Plugin.(api.Bootstrapper); ok {
			if err := plugin.Bootstrap(ctx); err != nil {
				return err
			}
		}
	}
	return nil
}

// Shutdown stops the node.
func (a *App) Shutdown(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	return a.K.Shutdown(ctx)
}

// parseNodeID parses the 16-hex node id from config.
func parseNodeID(s string) (identity.NodeID, error) {
	if len(s) != identity.HexLength {
		return 0, errs.InvalidArgument("node.id must be 16 hex characters")
	}
	var v uint64
	if _, err := fmt.Sscanf(s, "%016x", &v); err != nil {
		return 0, errs.Wrap(errs.CodeInvalidArgument, err, "invalid node.id")
	}
	return identity.NodeID(v), nil
}

// configuredPlugins returns the ordered list of plugin names to boot.
func configuredPlugins(cfg *dconfig.Config) []string {
	var names []string
	add := func(specs []dconfig.PluginSpec) {
		for _, s := range specs {
			if s.Enabled {
				names = append(names, s.Name)
			}
		}
	}
	add(cfg.Plugins.Adapters)
	add(cfg.Plugins.Actions)
	add(cfg.Plugins.Modules)
	return names
}

// enabledAdapter reports whether an adapter plugin is enabled in the config.
func enabledAdapter(cfg *dconfig.Config, name string) bool {
	for _, s := range cfg.Plugins.Adapters {
		if s.Name == name && s.Enabled {
			return true
		}
	}
	return false
}
