package spaces

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"time"
)

func (s *Service) turnLog(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Turn  string `json:"turn"`
		Limit int    `json:"limit"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	if e = s.Can(ctx, sp, identity.ID{}, req.Caller.ID, permission.RoomRead); e != nil {
		if admin := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); admin != nil {
			return nil, e
		}
	}
	eq := map[string]any{"space_id": sp.String()}
	if in.Turn != "" {
		eq["id"] = in.Turn
	}
	in.Limit, _ = helper.Paging(in.Limit, 0, 100, 500)
	var rows []turn.Turn
	if e = s.R.List(ctx, "room_turns", database.Filter{Equal: eq, OrderBy: "created_at", Asc: false, Limit: in.Limit}, &rows); e != nil {
		return nil, e
	}
	// Each turn fans out to one run per seeded agent; a run id is turn:bot.
	entries := []map[string]any{}
	live := []map[string]any{}
	queued := []map[string]any{}
	for _, t := range rows {
		for _, seed := range t.Seeds {
			id := t.ID.String() + ":" + seed
			name := seed
			if b, e := s.Bots.GetBot(ctx, identity.MustParse(seed)); e == nil {
				name = b.Name
			}
			run := map[string]any{"run_id": id, "turn_id": t.ID.String(), "room_id": t.RoomID.String(), "bot_id": seed, "bot_name": name, "status": t.Status, "prompt": t.Prompt, "created_at": t.CreatedAt, "updated_at": t.UpdatedAt}
			if !t.StartedAt.IsZero() {
				run["started_at"] = t.StartedAt
			}
			entries = append(entries, map[string]any{"at": t.CreatedAt, "kind": "accepted", "run_id": id, "turn_id": t.ID.String(), "room_id": t.RoomID.String(), "bot_id": seed, "bot_name": name, "text": "Turn accepted and persisted"})
			switch t.Status {
			case "queued":
				queued = append(queued, run)
			case "running", "blocked":
				live = append(live, run)
			default:
				entries = append(entries, map[string]any{"at": t.UpdatedAt, "kind": t.Status, "run_id": id, "turn_id": t.ID.String(), "room_id": t.RoomID.String(), "bot_id": seed, "bot_name": name, "text": t.Status, "error": t.Error, "prompt": t.Prompt, "duration_ms": max(positiveTime(t.EndedAt)-positiveTime(t.StartedAt), 0)})
			}
		}
	}
	return helper.JSON(map[string]any{"live": live, "queued": queued, "entries": entries})
}
func positiveTime(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}
