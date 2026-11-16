package spaces

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
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

// resolveDeskOpens fills each open op from the space's tools (name, and the
// frontend the window shows) and refuses tools that are not the space's.
//
// Tool opens from people clicking the dock need a static or app frontend.
// Interactive UIs are opened via appui_create (DeskWeb), not dock auto-open.
func (s *Service) resolveDeskOpens(ctx context.Context, spaceID identity.ID, ops []DeskOp) error {
	var tools []vmm.Tool
	for i := range ops {
		if ops[i].Op != "open" {
			continue
		}
		if ops[i].Kind == DeskFile || ops[i].Kind == DeskComputer || ops[i].Kind == DeskAgUi {
			continue
		}
		if ops[i].Kind == DeskWeb {
			if err := s.resolveWebOpen(ctx, spaceID, &ops[i], &tools); err != nil {
				return err
			}
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
		if appUI(t, ops[i].Microtool) != "" {
			ops[i].Tool, ops[i].Name, ops[i].Frontend = t.BotID, t.Name, DeskAppFrontend
			continue
		}
		switch t.Frontend {
		case "static":
			ops[i].Tool, ops[i].Name, ops[i].Frontend = t.BotID, t.Name, "static"
		default:
			if len(t.Commands) == 0 {
				return errs.InvalidArgument(t.Name + " has no frontend; present its result in your message, or open an interactive UI with appui_create")
			}
			return errs.InvalidArgument(t.Name + " has no static frontend; open an interactive UI with appui_create")
		}
	}
	return nil
}

// resolveWebOpen checks a web page window's page is a preview of this space
// and names the tool it is a frontend of, if any.
func (s *Service) resolveWebOpen(ctx context.Context, spaceID identity.ID, op *DeskOp, tools *[]vmm.Tool) error {
	page, _ := op.Args["page"].(string)
	if err := checkPage(page); err != nil {
		return err
	}
	id, err := identity.Parse(page[len("/v1/proxy/") : len("/v1/proxy/")+32])
	if err != nil {
		return errs.InvalidArgument("invalid preview id in " + page)
	}
	p, err := s.ProxyGet(ctx, id)
	if err != nil {
		return err
	}
	if p.SpaceID != spaceID {
		return errs.Permission("the page is a preview of another space")
	}
	if op.Title == "" {
		op.Title = p.Title
	}
	if op.Tool == "" || op.Tool == DeskWebTool {
		op.Tool, op.Name = DeskWebTool, "Web pages"
		return nil
	}
	if *tools == nil {
		if *tools, err = s.SpaceTools(ctx, spaceID, identity.ID{}); err != nil {
			return err
		}
	}
	for _, t := range *tools {
		if t.BotID != "" && (t.BotID == op.Tool || equalFoldName(t.Name, op.Tool)) {
			op.Tool, op.Name = t.BotID, t.Name
			return nil
		}
	}
	return errs.InvalidArgument(op.Tool + " is no tool of this space")
}

// appUI is the ui:// resource (an MCP App) [microtool] of [t] shows its
// results with, if it has one.
func appUI(t *vmm.Tool, microtool string) string {
	if microtool == "" {
		return ""
	}
	for _, c := range t.Commands {
		if c.Name == microtool {
			return c.UI
		}
	}
	return ""
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
	// A direct chat's desk is per person. The signed-in caller is that person;
	// the request context does not otherwise name them, so a read would miss
	// the windows an agent opened on their desk.
	ctx = helper.WithActor(ctx, req.Caller.ID)
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
	ctx = helper.WithActor(ctx, req.Caller.ID)
	if err := a.s.resolveDeskOpens(ctx, spaceID, in.Ops); err != nil {
		return nil, err
	}
	d, ids, err := a.s.UpdateDesk(ctx, spaceID, roomID, req.Caller.ID.String(), in.Ops)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"desktop": d, "ids": ids})
}
