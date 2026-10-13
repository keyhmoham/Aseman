// Typed namespace facades resolve the current provider for every call.
package auth

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
)

type spacesPortBridge struct{ K api.Kernel }

var _ SpacesPort = spacesPortBridge{}

func (p spacesPortBridge) CreateHomeSpace(ctx context.Context, owner identity.ID, handle string) (*space.Space, error) {
	var result0 *space.Space
	err := bridge.Invoke(ctx, p.K, "spaces", "CreateHomeSpace", []any{ctx, owner, handle}, &result0)
	return result0, err
}
func (p spacesPortBridge) HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error) {
	var result0 *space.Space
	err := bridge.Invoke(ctx, p.K, "spaces", "HomeSpace", []any{ctx, owner}, &result0)
	return result0, err
}
