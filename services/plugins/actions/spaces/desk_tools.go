package spaces

// Desk tools agents use: desk_state, desk_arrange and desk_close read and
// rearrange the room's desk. proxy_create may open a DeskWeb preview via
// openWebPage (no page review).

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
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
			out := map[string]any{"id": w.ID, "title": w.Title, "frontend": w.Frontend, "x": w.X, "y": w.Y, "w": w.W, "h": w.H}
			if w.Kind == DeskWeb {
				out["page"], out["tool"] = w.Page(), w.Name
			}
			if w.Kind == DeskFile {
				if id := w.FileID(); id != "" {
					out["file_id"] = id
				} else {
					out["path"] = w.FilePath()
				}
			}
			return out
		}
	}
	return nil
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

// turnPayer is who pays for what an agent's turn has designed: the person
// whose request it is, else the agent's own account.
func (s *Service) turnPayer(ctx context.Context) string {
	e := vmm.ExecutionFrom(ctx)
	if _, err := identity.Parse(e.ActorID); err == nil {
		return e.ActorID
	}
	if id, err := identity.Parse(e.AgentID); err == nil && s.Bots != nil {
		if rec, err := s.Bots.GetBot(ctx, id); err == nil {
			return rec.AccountID.String()
		}
	}
	return ""
}

// webPageInput names a sandbox preview page to open as a DeskWeb window.
type webPageInput struct {
	Page  string `json:"page"`
	Proxy string `json:"proxy"`
	// Elpian is the program of an Elpian app, run natively by the client.
	Elpian  string       `json:"elpian"`
	Path    string       `json:"path"`
	Tool    string       `json:"tool"`
	Title   string       `json:"title"`
	X       *float64     `json:"x"`
	Y       *float64     `json:"y"`
	W       *float64     `json:"w"`
	H       *float64     `json:"h"`
	Compact *DeskCompact `json:"compact"`
	Room    string       `json:"room"`
}

func (in webPageInput) page() string {
	page := strings.TrimSpace(in.Page)
	if page == "" && in.Proxy != "" {
		page = "/v1/proxy/" + strings.TrimSpace(in.Proxy) + "/"
	}
	if in.Path != "" {
		page = strings.TrimRight(page, "/") + "/" + strings.TrimLeft(in.Path, "/")
	}
	if i := strings.Index(page, "/v1/proxy/"); i > 0 {
		page = page[i:]
	}
	return page
}

// openWebPage opens a sandbox preview as a DeskWeb card (no page review).
func (s *Service) openWebPage(ctx context.Context, spaceID, roomID identity.ID, agentName string, in webPageInput) (Desktop, string, error) {
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return Desktop{}, "", err
	}
	page := in.page()
	w, h := in.W, in.H
	if w == nil && h == nil {
		dw, dh := 720.0, 600.0
		w, h = &dw, &dh
	}
	args := map[string]any{"page": page}
	if entry := strings.TrimSpace(in.Elpian); entry != "" {
		args["elpian"] = entry
	}
	ops := []DeskOp{{Op: "open", Kind: DeskWeb, Tool: in.Tool, Title: in.Title, Args: args,
		X: in.X, Y: in.Y, W: w, H: h, Compact: in.Compact}}
	if err := s.resolveDeskOpens(ctx, spaceID, ops); err != nil {
		return Desktop{}, "", err
	}
	d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return Desktop{}, "", err
	}
	return d, ids[0], nil
}
