// Typed namespace facades resolve the current provider for every call.
package usages

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
)

type spacesPortBridge struct{ K api.Kernel }

var _ SpacesPort = spacesPortBridge{}

func (p spacesPortBridge) MemberOf(ctx context.Context, spaceID identity.ID, user identity.ID) (bool, error) {
	var result0 bool
	err := bridge.Invoke(ctx, p.K, "spaces", "MemberOf", []any{ctx, spaceID, user}, &result0)
	return result0, err
}
