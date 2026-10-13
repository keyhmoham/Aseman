package spaces

import (
	"context"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/vmm/models/execution"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// beginToolEvent checkpoints intent before a side effect. Repeated call IDs replay
// only completed results; an ambiguous in-flight call requires reconciliation.
func (s *Service) beginToolEvent(ctx context.Context, e execution.Event) (execution.Event, bool, error) {
	p := vmm.ExecutionFrom(ctx)
	if p.ToolCallID == "" {
		return e, false, nil
	}
	e.ID = repo.ExecutionKey(p.RunID + "/" + p.StepID + "/" + p.AttemptID + "/" + p.AgentID + "/" + p.ToolCallID)
	e.Status = "running"
	if err := s.R.DB.Create(ctx, "execution_events", e.ID, &e); err == nil {
		return e, false, nil
	} else if errs.CodeOf(err) != errs.CodeAlreadyExists {
		return e, false, err
	}
	var old execution.Event
	if err := s.R.DB.Get(ctx, "execution_events", e.ID, &old); err != nil {
		return e, false, err
	}
	if old.Tool != e.Tool || old.Args != e.Args {
		return e, false, errs.Conflict("tool call ID reused with different arguments")
	}
	if old.Status == "done" {
		return old, true, nil
	}
	return old, false, errs.Conflict("previous tool call failed or has an uncertain outcome; inspect before retrying")
}

func (s *Service) finishToolEvent(ctx context.Context, e execution.Event, result string, toolErr error) error {
	if e.ID == "" {
		return nil
	}
	e.Result = result
	e.Status = "done"
	if toolErr != nil {
		e.Status = "failed"
		e.Result = vmm.ToolFailureResult(e.Tool, result, toolErr)
	}
	if err := s.R.RequireAtomicUpdates(); err != nil {
		return err
	}
	changed, err := s.R.CompareAndSwap(ctx, "execution_events", e.ID, map[string]any{"status": "running"}, &e)
	if err != nil {
		return err
	}
	if !changed {
		return errs.Conflict("tool event checkpoint conflict")
	}
	return nil
}
