package spaces

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func (s *Service) deskScope(ctx context.Context, caller identity.ID, space, room string) (identity.ID, identity.ID, error) {
	spaceID, err := identity.Parse(space)
	if err != nil {
		return identity.ID{}, identity.ID{}, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if room != "" && room != "home" {
		if roomID, err = identity.Parse(room); err != nil {
			return identity.ID{}, identity.ID{}, errs.InvalidArgument("invalid room id")
		}
	}
	if err := s.Can(ctx, spaceID, roomID, caller, permission.SpaceView); err != nil {
		return identity.ID{}, identity.ID{}, err
	}
	return spaceID, roomID, nil
}

// resolveDeskOpens fills each open op from the space's tools (name, frontend
// mode) and refuses tools that are not the space's or have no frontend.
// generative limits opens to generative frontends (what agents show).
func (s *Service) resolveDeskOpens(ctx context.Context, spaceID identity.ID, ops []DeskOp, generative bool) error {
	var tools []vmm.Tool
	for i := range ops {
		if ops[i].Op != "open" {
			continue
		}
		if ops[i].Kind == DeskComposed {
			// People reopen a composed widget (from a pin) as it was.
			continue
		}
		if tools == nil {
			var err error
			if tools, err = s.SpaceTools(ctx, spaceID, identity.ID{}); err != nil {
				return err
			}
		}
		var t *vmm.Tool
		for k := range tools {
			if tools[k].BotID != "" && (tools[k].BotID == ops[i].Tool || (ops[i].Tool != "" && equalFoldName(tools[k].Name, ops[i].Tool))) {
				t = &tools[k]
				break
			}
		}
		if t == nil {
			return errs.InvalidArgument(ops[i].Tool + " is no tool of this space")
		}
		switch {
		case generative && t.Frontend != "generative":
			return errs.InvalidArgument(t.Name + " has no generative frontend: present its result in your message, in Markdown")
		case t.Frontend == "":
			return errs.InvalidArgument(t.Name + " has no frontend to open")
		}
		ops[i].Tool, ops[i].Name, ops[i].Frontend = t.BotID, t.Name, t.Frontend
	}
	return nil
}

// deskGetAction implements spaces.desktop_get: a room's desk (room omitted
// or "home": the space's own).
type deskGetAction struct{ s *Service }

func (a *deskGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "desktop_get", Summary: "A room's desk: its open card windows, pins and viewport"}
}

func (a *deskGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, roomID, err := a.s.deskScope(ctx, req.Caller.ID, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	d, err := a.s.Desk(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"desktop": d, "room": deskKey(roomID)})
}

// deskUpdateAction implements spaces.desktop_update: ops on a room's desk,
// applied together.
type deskUpdateAction struct{ s *Service }

func (a *deskUpdateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "desktop_update", Summary: "Open, move, close and pin card windows on a room's desk"}
}

func (a *deskUpdateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string   `json:"space"`
		Room  string   `json:"room"`
		Ops   []DeskOp `json:"ops"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, roomID, err := a.s.deskScope(ctx, req.Caller.ID, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	if err := a.s.resolveDeskOpens(ctx, spaceID, in.Ops, false); err != nil {
		return nil, err
	}
	d, ids, err := a.s.UpdateDesk(ctx, spaceID, roomID, req.Caller.ID.String(), in.Ops)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"desktop": d, "ids": ids})
}
