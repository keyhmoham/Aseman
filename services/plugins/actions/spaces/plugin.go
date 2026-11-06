package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/schema"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "spaces-ns", Version: "1.0.0", Provides: []string{"service/spaces"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, log)
		s.Bots = botPortBridge{K: d.Kernel}
		s.Routines = routineManagerBridge{K: d.Kernel}
		s.Msg = messagePortBridge{K: d.Kernel}
		var cfg struct {
			Node struct {
				URL string `json:"url"`
			}
			Sandbox struct {
				Backend  string  `json:"backend"`
				Image    string  `json:"image"`
				CPU      float64 `json:"cpu"`
				MemoryMB int64   `json:"memory_mb"`
				DiskMB   int64   `json:"disk_mb"`
			}
		}
		if err := bridge.GlobalConfig(d, &cfg); err != nil {
			return module.Instance{}, err
		}
		s.NodeURL = cfg.Node.URL
		s.SandboxBackend = cfg.Sandbox.Backend
		s.SandboxImage = cfg.Sandbox.Image
		s.SandboxResources = bot.ResourceProfile{CPU: cfg.Sandbox.CPU, Memory: cfg.Sandbox.MemoryMB, Disk: cfg.Sandbox.DiskMB}
		return module.Instance{Models: schema.Models(), Mount: func(ctx context.Context) error {
			if err := s.encryptLegacyProxyTokens(ctx); err != nil {
				return err
			}
			go s.sweepOrphanFiles(ctx)
			go s.sweepTempThreads(context.WithoutCancel(ctx))
			return nil
		}, Service: s, Actions: BuildActions(s), Run: s.RunTurns, Close: func(ctx context.Context) error { s.StopAllSandboxes(ctx); return nil }}, nil
	})
}
