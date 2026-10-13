package message

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/message/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "message-ns", Version: "1.0.0", Provides: []string{"service/message"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, botMessengerBridge{K: d.Kernel}, log)
		s.Files = attachmentResolverBridge{K: d.Kernel}
		return module.Instance{Models: schema.Models(), Service: s, Actions: BuildActions(s)}, nil
	})
}
