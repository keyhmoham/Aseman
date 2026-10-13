package vmm

import (
	"context"
	"time"

	"github.com/tradera/tradera/plugins/adapters/vmm/models/execution"
)

func NewExecutionEvent(ctx context.Context, agentName, tool, args, result, status string) execution.Event {
	p := ExecutionFrom(ctx)
	return execution.Event{SpaceID: p.SpaceID, RoomID: p.RoomID, RunID: p.RunID, StepID: p.StepID, AttemptID: p.AttemptID, AgentID: p.AgentID, AgentName: agentName, Tool: tool, Args: args, Result: result, Status: status, At: time.Now().UTC()}
}
