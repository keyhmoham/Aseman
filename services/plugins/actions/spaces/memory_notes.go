package spaces

import (
	"context"
	"encoding/base64"
	"regexp"
	"sort"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The agents' notes live in the node's agent memory (the harness adapter's
// memory store), but people know them by the paths they had in the sandbox:
// the project's notes at AGENTS.md and each agent's at
// .aseman/agents/<agent>/AGENTS.md (with JOURNAL.md, what the agent most
// recently learned). For people, sandbox_files reads and writes those paths in
// the memory store, so the project's Memory screen shows and corrects what the
// agents really read. Agents keep their notes through their memory tools.
const (
	notesFile      = "AGENTS.md"
	agentNotesDir  = "/workspace/.aseman/agents"
	spaceNotesPath = "/workspace/" + notesFile
	// journalFile is what an agent most recently learned.
	journalFile = "JOURNAL.md"
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

// memoryNotes serves sandbox_files for the notes paths from the agents'
// memory. ok is false when the request is not about the notes: the sandbox
// serves it as before.
func (s *Service) memoryNotes(ctx context.Context, req *api.ActionRequest, spaceID identity.ID, operation, target, content, data string) (*api.ActionResponse, bool, error) {
	// People read and correct the agents' memory on the project's Memory
	// screen; an agent keeps its own through its memory tools.
	if req.Caller.Kind == "bot" {
		return nil, false, nil
	}
	return s.engineMemoryNotes(ctx, "harness", spaceID, operation, target, content, data)
}

func (s *Service) engineMemoryNotes(ctx context.Context, engine string, spaceID identity.ID, operation, target, content, data string) (*api.ActionResponse, bool, error) {
	var mem vmm.EngineMemory
	ok := false
	if s.agentMemoryFn != nil {
		mem = s.agentMemoryFn()
		ok = mem != nil
	} else {
		mem, ok = s.K.VMMFor(vmm.TypeHarness).(vmm.EngineMemory)
	}
	if !ok || mem == nil {
		return nil, false, nil
	}
	agents, err := s.spaceAgents(ctx, spaceID)
	if err != nil {
		return nil, false, err
	}
	if operation == "list" && target == agentNotesDir {
		items := []map[string]any{}
		for name := range agents {
			items = append(items, map[string]any{"name": name, "type": "dir", "size": 0})
		}
		sort.Slice(items, func(i, j int) bool { return items[i]["name"].(string) < items[j]["name"].(string) })
		resp, err := helper.JSON(map[string]any{"items": items})
		return resp, true, err
	}
	agentID, journal := "", false
	switch {
	case target == spaceNotesPath:
	case strings.HasPrefix(target, agentNotesDir+"/") &&
		(strings.HasSuffix(target, "/"+notesFile) || strings.HasSuffix(target, "/"+journalFile)):
		journal = strings.HasSuffix(target, "/"+journalFile)
		folder := strings.TrimPrefix(target, agentNotesDir+"/")
		folder = strings.TrimSuffix(strings.TrimSuffix(folder, "/"+notesFile), "/"+journalFile)
		rec, found := agents[folder]
		if strings.Contains(folder, "/") || !found {
			return nil, false, nil
		}
		agentID = rec.ID.String()
	default:
		return nil, false, nil
	}
	switch operation {
	case "read":
		view, err := mem.EngineMemoryRead(ctx, engine, spaceID.String(), agentID)
		if err != nil {
			return nil, true, errs.Wrap(errs.CodeUnavailable, err, "read the agents' memory")
		}
		text := view.SpaceNotes
		if agentID != "" {
			text = view.Notes
		}
		if journal {
			days := make([]string, 0, len(view.Journal))
			for _, day := range view.Journal {
				days = append(days, "# "+day.Day+"\n\n"+day.Text)
			}
			text = strings.Join(days, "\n")
		}
		resp, err := helper.JSON(map[string]any{"content": text, "data_base64": base64.StdEncoding.EncodeToString([]byte(text)),
			"size": len(text), "engine": engine})
		return resp, true, err
	case "write":
		if journal {
			return nil, true, errs.Permission("the journal is the agent's own record; correct its notes instead")
		}
		if data != "" {
			raw, err := base64.StdEncoding.DecodeString(data)
			if err != nil {
				return nil, true, errs.InvalidArgument("data_base64 is not valid base64")
			}
			content = string(raw)
		}
		if err := mem.EngineMemoryWrite(ctx, engine, spaceID.String(), agentID, content); err != nil {
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
		if err != nil || bot.AgentVMType(rec.VMType) != bot.VMTypeHarness || (rec.Kind != "" && rec.Kind != bot.KindAgent) {
			continue
		}
		out[slug(rec.Name)] = rec
	}
	return out, nil
}
