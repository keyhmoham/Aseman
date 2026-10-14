package spaces

// The desk tools agents use: frontend_show opens a tool's generative frontend
// on a result as a card window; desk_state, desk_arrange and desk_close read
// and rearrange the room's desk.

import (
	"context"
	"encoding/json"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
)

// deskRoom is the desk an agent tool acts on: the room it names, else the
// turn's.
func deskRoom(roomID identity.ID, room string) (identity.ID, error) {
	if room == "" {
		return roomID, nil
	}
	if room == "home" {
		return identity.ID{}, nil
	}
	id, err := identity.Parse(room)
	if err != nil {
		return identity.ID{}, errs.InvalidArgument("invalid room")
	}
	return id, nil
}

func windowJSON(d Desktop, id string) map[string]any {
	for _, w := range d.Windows {
		if w.ID == id {
			return map[string]any{"id": w.ID, "title": w.Title, "frontend": w.Frontend, "x": w.X, "y": w.Y, "w": w.W, "h": w.H}
		}
	}
	return nil
}

// showTool implements frontend_show: a tool's interface as a card window on
// the room's desk, filled with the result the agent got (the microtool it
// called, with the same arguments) or, without one, the tool itself. A tool
// without a generative frontend gets one the node generates for it (see
// resolveDeskOpens). People see it live and keep using it; it stays until
// someone closes it.
func (s *Service) showTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Tool      string         `json:"tool"`
		Microtool string         `json:"microtool"`
		Args      map[string]any `json:"args"`
		Title     string         `json:"title"`
		X         *float64       `json:"x"`
		Y         *float64       `json:"y"`
		W         *float64       `json:"w"`
		H         *float64       `json:"h"`
		Room      string         `json:"room"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("frontend_show arguments must be a JSON object")
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	ops := []DeskOp{{Op: "open", Tool: in.Tool, Title: in.Title, Microtool: in.Microtool, Args: in.Args, X: in.X, Y: in.Y, W: in.W, H: in.H}}
	if err := s.resolveDeskOpens(ctx, spaceID, ops); err != nil {
		return "", err
	}
	d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return "", err
	}
	out, _ := json.Marshal(map[string]any{"ok": true, "window": windowJSON(d, ids[0]), "desk": d.Summary()})
	return string(out), nil
}

// deskStateTool implements desk_state.
func (s *Service) deskStateTool(ctx context.Context, spaceID, roomID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Room string `json:"room"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	d, err := s.Desk(ctx, spaceID, target)
	if err != nil {
		return "", err
	}
	return d.Summary(), nil
}

// deskArrangeTool implements desk_arrange: moves and resizes windows.
func (s *Service) deskArrangeTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Windows []DeskOp `json:"windows"`
		Room    string   `json:"room"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil || len(in.Windows) == 0 {
		return "", errs.InvalidArgument("desk_arrange needs windows: [{id, x, y, w, h}]")
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	ops := make([]DeskOp, len(in.Windows))
	for i, w := range in.Windows {
		ops[i] = DeskOp{Op: "move", ID: w.ID, X: w.X, Y: w.Y, W: w.W, H: w.H}
	}
	d, _, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return "", err
	}
	return d.Summary(), nil
}

// deskCloseTool implements desk_close: windows by id, or all of a tool's.
func (s *Service) deskCloseTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		IDs  []string `json:"ids"`
		Tool string   `json:"tool"`
		Room string   `json:"room"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil || (len(in.IDs) == 0 && in.Tool == "") {
		return "", errs.InvalidArgument("desk_close needs ids or a tool")
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	var ops []DeskOp
	for _, id := range in.IDs {
		ops = append(ops, DeskOp{Op: "close", ID: id})
	}
	if in.Tool != "" {
		tool := in.Tool
		if tools, err := s.SpaceTools(ctx, spaceID, identity.ID{}); err == nil {
			for _, t := range tools {
				if t.BotID != "" && equalFoldName(t.Name, tool) {
					tool = t.BotID
				}
			}
		}
		ops = append(ops, DeskOp{Op: "close_tool", Tool: tool})
	}
	d, _, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return "", err
	}
	return d.Summary(), nil
}

// deskNote is the desk part of an agent's turn note.
func (s *Service) deskNote(ctx context.Context, spaceID, roomID identity.ID) string {
	d, err := s.Desk(ctx, spaceID, roomID)
	if err != nil {
		return ""
	}
	return d.Summary()
}
