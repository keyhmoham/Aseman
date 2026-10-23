package spaces

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/widget"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// RoomWidgets returns the live desk-widget DSL for every app
// installed in a room. The DSL is produced by asking each app's backend VM
// ({"op":"widget",...}), which lets a widget update on the client's polling
// interval. When the VM cannot answer, the stored widget/dsl metadata is used,
// falling back to a generated default.
func (s *Service) RoomWidgets(ctx context.Context, spaceID, roomID identity.ID) ([]map[string]any, error) {
	eq := map[string]any{
		"space_id": spaceID.String(),
		"role":     string(membership.RoleBot),
	}
	if !roomID.IsZero() {
		eq["room_id"] = roomID.String()
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: eq}, &mems); err != nil {
		return nil, err
	}
	var out []map[string]any
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil {
			continue
		}
		if rec.Kind != bot.KindTool {
			continue
		}
		// The shared per-space sandbox is a computer, not a desk app.
		if rec.IsSandbox() {
			continue
		}
		w := s.widgetFor(ctx, spaceID, roomID, rec)
		out = append(out, map[string]any{
			"bot_id":     rec.ID.String(),
			"account_id": rec.AccountID.String(),
			"name":       rec.Name,
			"kind":       rec.Kind,
			"status":     rec.Status,
			"dsl":        w,
		})
	}
	return out, nil
}

// widgetFor resolves the desk-widget DSL for one app: live from its backend
// VM, else stored metadata, else a generated default.
func (s *Service) widgetFor(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot) *widget.Widget {
	raw := s.liveWidgetDSL(ctx, spaceID, roomID, rec)
	if raw == "" {
		raw = s.Bots.Widget(ctx, rec.ID)
	}
	if raw != "" {
		var parsed widget.Widget
		if json.Unmarshal([]byte(raw), &parsed) == nil && validWidget(&parsed) {
			if parsed.Title == "" {
				parsed.Title = rec.Name
			}
			if parsed.BotID == "" {
				parsed.BotID = rec.ID.String()
			}
			if parsed.RefreshSec == 0 {
				parsed.RefreshSec = 10
			}
			return &parsed
		}
	}
	def := widget.Default(rec)
	def.RefreshSec = 10
	return def
}

// validWidget rejects replies that are valid JSON but not a widget document
// (no rows and no title means the backend answered with something unrelated).
func validWidget(w *widget.Widget) bool {
	return len(w.Rows) > 0 || w.Title != "" || w.Version > 0
}

// liveWidgetDSL asks an app's backend VM for its current widget DSL. The
// well-known "widget" op lets the backend serve live data on every poll.
func (s *Service) liveWidgetDSL(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot) string {
	if rec.Kind == bot.KindAgent {
		return ""
	}
	args := fmt.Sprintf(`{"space":%q,"room":%q}`, spaceID.String(), roomID.String())
	reply, err := s.AskBot(ctx, spaceID, rec.ID, `{"op":"widget","args":`+args+`}`, nil, nil)
	if err != nil {
		return ""
	}
	reply = strings.TrimSpace(reply)
	if reply == "" || !json.Valid([]byte(reply)) {
		return ""
	}
	return reply
}

// widgetListAction implements spaces.widget_list.
type widgetListAction struct{ s *Service }

func (a *widgetListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "widget_list", Summary: "List the desk-widget DSLs of apps installed in a room"}
}
func (a *widgetListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if err := a.s.Can(ctx, spaceID, roomID, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	ws, err := a.s.RoomWidgets(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"widgets": ws})
}

// widgetActionAction implements spaces.widget_action.
type widgetActionAction struct{ s *Service }

func (a *widgetActionAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "widget_action", Summary: "Run a widget action against an app backend VM (static ask)"}
}
func (a *widgetActionAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string         `json:"space"`
		Bot   string         `json:"bot"`
		Op    string         `json:"op"`
		Args  map[string]any `json:"args,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Op) == "" {
		return nil, errs.InvalidArgument("op required")
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	botID, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	if _, err := a.s.SpaceMembership(ctx, spaceID, req.Caller.ID); err != nil {
		return nil, errs.Permission("not a member of the space")
	}
	payload := map[string]any{"op": in.Op}
	if in.Args != nil {
		payload["args"] = in.Args
	}
	body, _ := json.Marshal(payload)
	reply, err := a.s.AskBot(ctx, spaceID, botID, string(body), nil, nil)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": botID.String(), "op": in.Op, "reply": reply})
}
