package helper

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"
)

// Action keeps small namespace-owned handlers on the same protocol-neutral
// action boundary as the existing typed controllers.
type Action struct {
	Namespace, Name, Summary string
	Handler                  func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)
}

func (a Action) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: a.Namespace, Name: a.Name, Summary: a.Summary}
}
func (a Action) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return a.Handler(ctx, req)
}
