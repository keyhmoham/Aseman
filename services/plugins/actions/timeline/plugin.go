package timeline

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/support/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "timeline-ns", Version: "1.0.0", Provides: []string{"service/timeline"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		s := NewService(d.Kernel, r, d.Logger)
		return module.Instance{Service: s, Actions: Actions(s, d.Kernel), Models: append(schema.Models(), Models()...), Run: s.Start}, nil
	})
}

// Actions are the namespace's actions: the admin's view of the timelines.
func Actions(s *Service, k api.Kernel) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "timeline", Name: "status", Summary: "The spaces' timelines: whether they are kept and how far each feed has been read",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireNodeAdmin(ctx, s.R, req, k.Env()["admin_handle"]); err != nil {
					return nil, err
				}
				st, err := s.Status(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(st)
			}},
	}
}
