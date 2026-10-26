package spaces

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// roomInfoTool implements the room_info tool: it answers who/what is in a room
// (or the whole workspace): the people (human members), the agents (bot members)
// and the tools available to agents. aseman uses it to know who it can talk
// to, who it can dispatch work to and what tools exist before planning.
func (s *Service) roomInfoTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Room string `json:"room"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	var roomID identity.ID
	if in.Room != "" {
		r, err := identity.Parse(in.Room)
		if err != nil {
			return "", errs.InvalidArgument("invalid room id")
		}
		roomID = r
	}
	eq := map[string]any{"space_id": spaceID.String()}
	if !roomID.IsZero() {
		eq["room_id"] = roomID.String()
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: eq, OrderBy: "created_at", Asc: true,
	}, &mems); err != nil {
		return "", err
	}
	people := []map[string]any{}
	agents := []map[string]any{}
	for i := range mems {
		role := string(mems[i].Role)
		entry := map[string]any{
			"id": mems[i].MemberID.String(), "role": role,
			"joined_at": mems[i].JoinedAt,
		}
		var acc account.Account
		if s.R.Get(ctx, "accounts", mems[i].MemberID, &acc) == nil {
			entry["handle"] = acc.Handle
			entry["kind"] = string(acc.Kind)
		}
		if mems[i].Role == membership.RoleBot {
			if rec, err := s.botForMember(ctx, mems[i].MemberID); err == nil {
				entry["name"] = rec.Name
				entry["bot_id"] = rec.ID.String()
				entry["vm_type"] = string(rec.VMType)
			}
			agents = append(agents, entry)
		} else {
			people = append(people, entry)
		}
	}
	tools := []map[string]any{}
	toolRefs, err := s.SpaceTools(ctx, spaceID, roomID)
	if err == nil {
		for _, t := range toolRefs {
			tools = append(tools, map[string]any{
				"name": t.Name, "kind": t.Kind, "description": t.Description,
			})
		}
	}
	out, _ := json.Marshal(map[string]any{
		"room":   roomID.String(),
		"people": people, "agents": agents, "tools": tools,
	})
	return string(out), nil
}

// askUserTool implements the ask_user tool: an agent (or aseman) asks the
// user a clarifying question. Posts a single AG-UI Question card in chat
// (options as tappable choices) and pauses until the user answers. Do not
// also paste the same options as prose — the card is the UI.
func (s *Service) askUserTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Question string   `json:"question"`
		Options  []string `json:"options"`
		Input    string   `json:"input"`
		Caption  string   `json:"caption"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	if in.Question == "" && in.Input != "" {
		for _, pair := range strings.Split(in.Input, "&") {
			if i := strings.IndexByte(pair, '='); i >= 0 {
				k, v := strings.TrimSpace(pair[:i]), strings.TrimSpace(pair[i+1:])
				if k == "question" || k == "q" {
					in.Question = v
				}
			}
		}
	}
	if strings.TrimSpace(in.Question) == "" {
		return "", errs.InvalidArgument("ask_user requires a question")
	}
	if len(in.Options) > 3 {
		return "", errs.InvalidArgument("ask_user accepts at most three options")
	}
	opts := make([]string, 0, len(in.Options))
	for _, option := range in.Options {
		if t := strings.TrimSpace(option); t != "" {
			opts = append(opts, t)
		}
	}
	question := strings.TrimSpace(in.Question)
	surf := agui.QuestionSurface(question, opts)
	body, err := agui.FormatMessage(strings.TrimSpace(in.Caption), surf)
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "encode ask_user agui")
	}
	summary := "Asked the user via AG-UI in chat. End this invocation and await their answer; do not assume an option was selected.\nQuestion: " + question
	for _, o := range opts {
		summary += "\n- " + o
	}
	sender, err := s.toolSender(ctx)
	if err != nil {
		return summary, nil
	}
	roomID, _ := s.toolRoom(ctx, "")
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true); err == nil {
		_ = s.postMessage(ctx, spaceID, roomID, sender, body, message.KindMessage)
	}
	return summary, nil
}
