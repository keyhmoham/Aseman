package spaces

// The desk tools agents use: frontend_show opens a tool's generative frontend
// on a result as a card window; desk_state, desk_arrange and desk_close read
// and rearrange the room's desk.

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
			if w.Frontend == DeskAutoFrontend {
				out["designed_for"], out["status"] = w.Request, w.Status
			}
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
		Request   string         `json:"request"`
		X         *float64       `json:"x"`
		Y         *float64       `json:"y"`
		W         *float64       `json:"w"`
		H         *float64       `json:"h"`
		Compact   *DeskCompact   `json:"compact"`
		Room      string         `json:"room"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("frontend_show arguments must be a JSON object")
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	ops := []DeskOp{{Op: "open", Tool: in.Tool, Title: in.Title, Request: in.Request, Microtool: in.Microtool, Args: in.Args, X: in.X, Y: in.Y, W: in.W, H: in.H, Compact: in.Compact}}
	if err := s.resolveDeskOpens(ctx, spaceID, ops); err != nil {
		return "", err
	}
	d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return "", err
	}
	s.designOpened(ctx, spaceID, target, d, ids, s.turnPayer(ctx))
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

// webShowInput is a web_show call (and the desk part of proxy_create's).
type webShowInput struct {
	// Page is a preview gateway path (what proxy_create returned), with the
	// page's own path inside it; Proxy + Path name it by the preview's id.
	Page    string       `json:"page"`
	Proxy   string       `json:"proxy"`
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

func (in webShowInput) page() string {
	page := strings.TrimSpace(in.Page)
	if page == "" && in.Proxy != "" {
		page = "/v1/proxy/" + strings.TrimSpace(in.Proxy) + "/"
	}
	if in.Path != "" {
		page = strings.TrimRight(page, "/") + "/" + strings.TrimLeft(in.Path, "/")
	}
	// A page path the agent wrote with the node's origin in front.
	if i := strings.Index(page, "/v1/proxy/"); i > 0 {
		page = page[i:]
	}
	return page
}

// showPage opens a web page (a preview of the space) as a card window on a
// room's desk, as the frontend of [in.Tool] when it names one. The page is
// reviewed first (page_review.go): one that does not work is not opened, and
// the agent gets the report; the review of one that opens comes back too.
func (s *Service) showPage(ctx context.Context, spaceID, roomID identity.ID, agentName string, in webShowInput) (Desktop, string, *pageReview, error) {
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return Desktop{}, "", nil, err
	}
	review := s.reviewPage(ctx, spaceID, in.page(), in.Tool)
	if review != nil && review.broken > 0 {
		return Desktop{}, "", review, errs.InvalidArgument(review.report(false))
	}
	w, h := in.W, in.H
	if w == nil && h == nil {
		// A page needs more room than a result card.
		dw, dh := 720.0, 600.0
		w, h = &dw, &dh
	}
	ops := []DeskOp{{Op: "open", Kind: DeskWeb, Tool: in.Tool, Title: in.Title, Args: map[string]any{"page": in.page()},
		X: in.X, Y: in.Y, W: w, H: h, Compact: in.Compact}}
	if err := s.resolveDeskOpens(ctx, spaceID, ops); err != nil {
		return Desktop{}, "", review, err
	}
	d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, ops)
	if err != nil {
		return Desktop{}, "", review, err
	}
	return d, ids[0], review, nil
}

// webShowTool implements web_show: a web page served from the sandbox
// (exposed with proxy_create) as a card window on the room's desk, like a
// tool's frontend; with tool, it is that tool's frontend.
func (s *Service) webShowTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in webShowInput
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("web_show arguments must be a JSON object")
	}
	d, id, review, err := s.showPage(ctx, spaceID, roomID, agentName, in)
	if err != nil {
		return "", err
	}
	out := map[string]any{"ok": true, "window": windowJSON(d, id), "desk": d.Summary()}
	if review != nil {
		out["review"] = review
		if !review.Passed || len(review.Issues) > 0 {
			out["next"] = review.report(true)
		}
	}
	raw, _ := json.Marshal(out)
	return string(raw), nil
}
