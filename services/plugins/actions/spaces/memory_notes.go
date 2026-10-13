package spaces

import (
	"context"
	"encoding/base64"
	"regexp"
	"sort"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/openviking"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// The agents' notes live in OpenViking (the agents' memory server), but people
// know them by the paths they had in the sandbox: the project's notes at
// AGENTS.md and each agent's at .tradera/agents/<agent>/AGENTS.md. For
// people, sandbox_files reads and writes those paths in OpenViking, so the
// project's Memory screen shows and corrects what the agents really read.
// Agents themselves keep their notes through their memory tools; their reads
// of these paths still reach the sandbox (that is how the runtime imports the
// notes kept there before).
const (
	notesFile      = "AGENTS.md"
	agentNotesDir  = "/workspace/.tradera/agents"
	spaceNotesPath = "/workspace/" + notesFile
	notesReader    = "people" // whom a read of the shared notes acts as
)

var agentSlug = regexp.MustCompile(`[^a-z0-9-]+`)

// slug is an agent's folder name, as the runtime makes it.
func slug(name string) string {
	s := strings.Trim(agentSlug.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if s == "" {
		return "agent"
	}
	return s
}

// memoryNotes serves sandbox_files for the notes paths from OpenViking. ok is
// false when the request is not about the notes (or the node has no memory
// server, or the notes are not there yet): the sandbox serves it as before.
func (s *Service) memoryNotes(ctx context.Context, req *api.ActionRequest, spaceID identity.ID, operation, target, content, data string) (*api.ActionResponse, bool, error) {
	ov := openviking.FromEnv()
	if ov == nil || req.Caller.Kind == "bot" {
		return nil, false, nil
	}
	account := openviking.SpaceAccount(spaceID.String())
	if operation == "list" && target == agentNotesDir {
		agents, err := s.spaceAgents(ctx, spaceID)
		if err != nil {
			return nil, false, err
		}
		items := []map[string]any{}
		for name := range agents {
			items = append(items, map[string]any{"name": name, "type": "dir", "size": 0})
		}
		sort.Slice(items, func(i, j int) bool { return items[i]["name"].(string) < items[j]["name"].(string) })
		resp, err := helper.JSON(map[string]any{"items": items})
		return resp, true, err
	}
	uri, user := "", ""
	switch {
	case target == spaceNotesPath:
		uri, user = openviking.SpaceNotes, notesReader
	case strings.HasPrefix(target, agentNotesDir+"/") && strings.HasSuffix(target, "/"+notesFile):
		folder := strings.TrimSuffix(strings.TrimPrefix(target, agentNotesDir+"/"), "/"+notesFile)
		if strings.Contains(folder, "/") {
			return nil, false, nil
		}
		agents, err := s.spaceAgents(ctx, spaceID)
		if err != nil {
			return nil, false, err
		}
		rec, ok := agents[folder]
		if !ok {
			return nil, false, nil
		}
		user = openviking.AgentUser(rec.ID.String())
		uri = openviking.AgentNotes(user)
	default:
		return nil, false, nil
	}
	switch operation {
	case "read":
		text, err := ov.Read(ctx, account, user, uri)
		if openviking.NotFound(err) {
			// Not in memory yet: what the sandbox still holds is the notes.
			return nil, false, nil
		}
		if err != nil {
			return nil, true, errs.Wrap(errs.CodeUnavailable, err, "read the agents' memory")
		}
		resp, err := helper.JSON(map[string]any{"content": text, "data_base64": base64.StdEncoding.EncodeToString([]byte(text)),
			"size": len(text)})
		return resp, true, err
	case "write":
		if data != "" {
			raw, err := base64.StdEncoding.DecodeString(data)
			if err != nil {
				return nil, true, errs.InvalidArgument("data_base64 is not valid base64")
			}
			content = string(raw)
		}
		if err := ov.Write(ctx, account, user, uri, content); err != nil {
			return nil, true, errs.Wrap(errs.CodeUnavailable, err, "save to the agents' memory")
		}
		resp, err := helper.JSON(map[string]any{"ok": true})
		return resp, true, err
	}
	return nil, false, nil
}

// spaceAgents are the space's agents by their notes folder name.
func (s *Service) spaceAgents(ctx context.Context, spaceID identity.ID) (map[string]*bot.Bot, error) {
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	out := map[string]*bot.Bot{}
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil || bot.AgentVMType(rec.VMType) != bot.VMTypeDeepAgents || (rec.Kind != "" && rec.Kind != bot.KindAgent) {
			continue
		}
		out[slug(rec.Name)] = rec
	}
	return out, nil
}
