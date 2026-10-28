package proactive

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "proactive-ns", Version: "1.0.0", Provides: []string{"service/proactive"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Google, s.Spaces, s.LLM, s.Users = googleBridge{K: d.Kernel}, spacesBridge{K: d.Kernel}, llmBridge{K: d.Kernel}, usersBridge{K: d.Kernel}
		return module.Instance{Service: s, Models: pm.Models(), Actions: s.actions(), Run: s.Run}, nil
	})
}
