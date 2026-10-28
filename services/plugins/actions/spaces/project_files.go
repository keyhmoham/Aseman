package spaces

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

// ProjectFiles lists, reads or writes a project computer's workspace for
// another namespace (shared folders), as [caller]: exactly what the computer's
// file browser does for them, with the same checks (reading needs the
// project's read permission, writing its send permission) and the same
// answers (missing, asleep). A write wakes the computer when it must.
func (s *Service) ProjectFiles(ctx context.Context, caller identity.ID, space, operation, p, content string) (map[string]any, error) {
	switch operation {
	case "list", "read", "write":
	default:
		return nil, errs.InvalidArgument("operation is list, read or write")
	}
	body, err := json.Marshal(map[string]any{"space": space, "operation": operation, "path": p, "content": content, "wake": operation == "write"})
	if err != nil {
		return nil, err
	}
	resp, err := s.sandboxFilesAction(ctx, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: body})
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if resp != nil && len(resp.Body) > 0 {
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			return nil, err
		}
	}
	return out, nil
}
