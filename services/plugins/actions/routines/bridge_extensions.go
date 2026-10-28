package routine

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
)

func (p spacesPortBridge) RunScheduledTask(ctx context.Context, space, room, actor identity.ID, task string) (string, error) {
	var result string
	err := bridge.Invoke(ctx, p.K, "spaces", "RunScheduledTask", []any{ctx, space, room, actor, task}, &result)
	return result, err
}

type llmBridge struct{ K api.Kernel }

func (b llmBridge) Complete(ctx context.Context, c Completion) (CompletionResult, error) {
	var out CompletionResult
	err := bridge.Invoke(ctx, b.K, "llm", "Complete", []any{ctx, c}, &out)
	return out, err
}
