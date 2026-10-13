package bots

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/bots/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "bots-ns", Version: "1.0.0", Provides: []string{"service/bots"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, log)
		s.Files = attachmentResolverBridge{K: d.Kernel}
		s.Biller = billerBridge{K: d.Kernel}
		s.LLM = llmPortBridge{K: d.Kernel}
		s.UsageLog = usageRecorderBridge{K: d.Kernel}
		s.Agents = agentAskerBridge{K: d.Kernel}
		return module.Instance{Models: schema.Models(), Service: s, Actions: BuildActions(s), Bootstrap: s.Bootstrap}, nil
	})
}
