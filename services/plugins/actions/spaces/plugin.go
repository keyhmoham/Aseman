package spaces

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
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
		s.SandboxBackend = cfg.Sandbox.Backend
		s.SandboxImage = cfg.Sandbox.Image
		s.SandboxResources = bot.ResourceProfile{CPU: cfg.Sandbox.CPU, Memory: cfg.Sandbox.MemoryMB, Disk: cfg.Sandbox.DiskMB}
		return module.Instance{Models: schema.Models(), Mount: s.encryptLegacyProxyTokens, Service: s, Actions: BuildActions(s), Run: s.RunTurns, Close: func(ctx context.Context) error { s.StopAllSandboxes(ctx); return nil }}, nil
	})
}
