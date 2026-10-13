package spaces

import (
	"context"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"strings"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/spaces/models/invitation"
)

// participants resolves account ids to the public identity a client renders
// next to a member or a message (handle, kind, display name, avatar and, for
// bot accounts, the bot id). Lookups are memoized per request.
type participants struct {
	s     *Service
	cache map[string]map[string]any
}

func (s *Service) participants() *participants {
	return &participants{s: s, cache: map[string]map[string]any{}}
}

func (p *participants) get(ctx context.Context, id identity.ID) map[string]any {
	key := id.String()
	if v, ok := p.cache[key]; ok {
		return v
	}
	out := map[string]any{"id": key}
	var acc account.Account
	if p.s.R.Get(ctx, "accounts", id, &acc) == nil {
		out["handle"] = acc.Handle
		out["kind"] = string(acc.Kind)
		out["display_name"] = acc.Handle
		if acc.Kind == account.KindBot {
			if rec, err := p.s.botForMember(ctx, id); err == nil {
				out["bot_id"] = rec.ID.String()
				out["display_name"] = rec.Name
			}
		}
	}
	if p.s.M != nil {
		if rec, err := p.s.M.Get(ctx, id); err == nil && rec != nil {
			if profile, ok := rec.Tree["profile"].(map[string]any); ok {
				// A bot keeps the name it was given; a person is named the same
				// way everywhere (helper.PersonName).
				if acc.Kind != account.KindBot {
					out["display_name"] = helper.PersonName(profile, acc.Handle)
				} else if out["display_name"] == acc.Handle {
					out["display_name"] = helper.BotName(profile, acc.Handle)
				}
				if avatar, _ := profile["avatar"].(string); strings.TrimSpace(avatar) != "" {
					out["avatar"] = strings.TrimSpace(avatar)
				}
			}
		}
	}
	p.cache[key] = out
	return out
}

// invitationViews renders invitations with the workspace name and the public
// identity of the inviter and invitee, which is what an inbox shows.
func (s *Service) invitationViews(ctx context.Context, rows []invitation.Invitation) []map[string]any {
	people := s.participants()
	names := map[string]string{}
	out := make([]map[string]any, 0, len(rows))
	for _, inv := range rows {
		name, ok := names[inv.SpaceID.String()]
		if !ok {
			if sp, err := s.GetSpace(ctx, inv.SpaceID); err == nil {
				name = sp.Name
			}
			names[inv.SpaceID.String()] = name
		}
		out = append(out, map[string]any{
			"id": inv.ID.String(), "space_id": inv.SpaceID.String(), "space_name": name,
			"room_id": inv.RoomID.String(), "role": inv.Role, "status": inv.Status,
			"inviter": people.get(ctx, inv.InviterID), "invitee": people.get(ctx, inv.InviteeID),
			"expires_at": inv.ExpiresAt, "created_at": inv.CreatedAt,
		})
	}
	return out
}
