package bridge

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
)

// ActionAlias preserves an existing API name in its owning namespace while
// delegating to the current provider of the implementation namespace.
func ActionAlias(k api.Kernel, namespace, name, targetNamespace, targetName, summary string) api.Action {
	return &actionAlias{k: k, meta: api.ActionMeta{Namespace: namespace, Name: name, Summary: summary}, targetNamespace: targetNamespace, targetName: targetName}
}

type actionAlias struct {
	k                           api.Kernel
	meta                        api.ActionMeta
	targetNamespace, targetName string
}

func (a *actionAlias) Meta() api.ActionMeta { return a.meta }
func (a *actionAlias) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return a.k.Actions().Dispatch(ctx, a.targetNamespace, a.targetName, req)
}
