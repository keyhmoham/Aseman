package routine

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
)

func (p spacesPortBridge) RunScheduledTask(ctx context.Context, space, room, actor identity.ID, task string) (string, error) {
	var result string
	err := bridge.Invoke(ctx, p.K, "spaces", "RunScheduledTask", []any{ctx, space, room, actor, task}, &result)
	return result, err
}
