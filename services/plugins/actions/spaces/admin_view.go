package spaces

import (
	"context"
	"github.com/aseman/aseman/pkg/errs"
	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	usage "github.com/aseman/aseman/plugins/actions/usage/models"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The admin console's view of a space: who owns it, what state its computer is
// in, and who and what works in it. Admins are not members, so none of this can
// come from the member-scoped actions (members_list, bots_list).

// adminOwner describes a space's owner; deleted is true when the account is gone.
func (s *Service) adminOwner(ctx context.Context, ownerID identity.ID) map[string]any {
	out := map[string]any{"id": ownerID.String(), "deleted": true}
	var acc account.Account
	if s.R.Get(ctx, "accounts", ownerID, &acc) != nil {
		return out
	}
	out["deleted"] = false
	out["handle"] = acc.Handle
	out["email"] = acc.Email
	out["email_verified"] = acc.EmailVerified
	out["status"] = acc.Status
	out["role"] = acc.Role
	if who := s.participants().get(ctx, ownerID); who != nil {
		if v, ok := who["display_name"]; ok {
			out["display_name"] = v
		}
	}
	return out
}

// machineState names the state of a space's shared computer for people:
// none (never started), awake, asleep, starting or failed.
func machineState(status string) string {
	switch bot.Status(status) {
	case bot.StatusRunning:
		return "awake"
	case bot.StatusStopped, bot.StatusPaused, bot.StatusEnded:
		return "asleep"
	case bot.StatusPending, bot.StatusCreating:
		return "starting"
	case bot.StatusFailed:
		return "failed"
	}
	return "none"
}

// adminMachine is the space's computer: its state, runtime and image.
func (s *Service) adminMachine(ctx context.Context, spaceID identity.ID) map[string]any {
	out := map[string]any{"state": "none"}
	if s.Bots == nil {
		return out
	}
	st, err := s.SandboxStatus(ctx, spaceID)
	if err != nil || st == nil {
		return out
	}
	raw, _ := st["status"].(bot.Status)
	if raw == "" {
		if str, ok := st["status"].(string); ok {
			raw = bot.Status(str)
		}
	}
	out["state"] = machineState(string(raw))
	out["status"] = string(raw)
	if v, ok := st["vm_type"]; ok {
		out["vm_type"] = v
	}
	if v, ok := st["bot_id"]; ok {
		out["bot_id"] = v
	}
	out["idle_stop"] = st["idle_stop"]
	return out
}

// adminPeople lists a space's people and the bots that work in it, once each
// (memberships are also stored per room; only the space-level rows count).
func (s *Service) adminPeople(ctx context.Context, spaceID identity.ID) (members []map[string]any, workers []map[string]any) {
	var mems []membership.Membership
	if s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "room_id": zeroRoom}, OrderBy: "created_at", Asc: true,
	}, &mems) != nil {
		return nil, nil
	}
	people := s.participants()
	seen := map[string]bool{}
	for i := range mems {
		m := mems[i]
		if seen[m.MemberID.String()] {
			continue
		}
		seen[m.MemberID.String()] = true
		if m.Role == membership.RoleBot {
			if s.Bots == nil {
				continue
			}
			rec, err := s.botForMember(ctx, m.MemberID)
			if err != nil {
				continue
			}
			workers = append(workers, map[string]any{
				"id": rec.ID.String(), "name": rec.Name, "kind": string(rec.Kind), "status": string(rec.Status),
				"owner_id": rec.OwnerID.String(), "joined_at": m.JoinedAt,
				"sandbox": rec.IsSandbox(), "builtin": rec.IsBuiltinLead(),
			})
			continue
		}
		row := map[string]any{"member_id": m.MemberID.String(), "role": string(m.Role), "joined_at": m.JoinedAt, "deleted": true}
		var acc account.Account
		if s.R.Get(ctx, "accounts", m.MemberID, &acc) == nil {
			row["deleted"] = false
			row["handle"] = acc.Handle
			row["email"] = acc.Email
			row["status"] = acc.Status
		}
		if who := people.get(ctx, m.MemberID); who != nil {
			if v, ok := who["display_name"]; ok {
				row["display_name"] = v
			}
		}
		members = append(members, row)
	}
	return members, workers
}

// adminListExtras are the per-row fields of the admin project list.
func (s *Service) adminListExtras(ctx context.Context, sp space.Space) map[string]any {
	owner := s.adminOwner(ctx, sp.OwnerID)
	agents := 0
	var mems []membership.Membership
	if s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String(), "room_id": zeroRoom, "role": string(membership.RoleBot)},
	}, &mems) == nil && s.Bots != nil {
		for i := range mems {
			if rec, err := s.botForMember(ctx, mems[i].MemberID); err == nil && rec.Kind == bot.KindAgent && !rec.IsBuiltinLead() {
				agents++
			}
		}
	}
	return map[string]any{"owner": owner, "agents": agents, "machine": s.adminMachine(ctx, sp.ID)}
}

// adminWorkLog is a project's recent agent runs, each with the events that
// happened in its room while it ran (plans, tool calls, replies). Admins are
// not members, so spaces.updates cannot serve them.
func (s *Service) adminWorkLog(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Limit int    `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 100 {
		in.Limit = 30
	}
	var turns []turn.Turn
	if err := s.R.List(ctx, "room_turns", database.Filter{Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: in.Limit}, &turns); err != nil {
		return nil, err
	}
	// Metered usage belongs to the admin log, never to reply text. Include
	// direct asks and DMs too, even when they have no durable room turn.
	var usages []usage.Usage
	if err := s.R.List(ctx, "usages", database.Filter{
		Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: 100,
	}, &usages); err != nil {
		return nil, err
	}
	usageEvents := make([]map[string]any, 0, len(usages))
	// Usage records name the provider by id; the admin reads its name.
	providerNames := map[string]string{}
	providerName := func(id string) string {
		if name, ok := providerNames[id]; ok {
			return name
		}
		name := id
		if pid, err := identity.Parse(id); err == nil {
			var p llmprovider.Provider
			if s.R.Get(ctx, "llm_providers", pid, &p) == nil && p.Name != "" {
				name = p.Name
			}
		}
		providerNames[id] = name
		return name
	}
	for _, u := range usages {
		summary := (usage.Delta{TokensIn: u.TokensIn, TokensOut: u.TokensOut, Images: u.Images, Cost: u.Cost}).Summary()
		if summary == "" && u.DecisionIn+u.DecisionOut == 0 {
			continue
		}
		usageEvents = append(usageEvents, map[string]any{
			"id": u.ID.String(), "created_at": u.Entity.CreatedAt, "bot_name": u.BotName,
			"room_id": u.RoomID.String(), "request_id": u.RequestID, "summary": summary,
			"provider": providerName(u.Provider), "model": u.Model, "kind": u.Kind, "tokens_in": u.TokensIn, "tokens_out": u.TokensOut, "cost": u.Cost,
			"decision_in": u.DecisionIn, "decision_out": u.DecisionOut, "decision": u.Decision,
			"images": u.Images, "image_count": u.ImageCount, "image_in": u.ImageIn, "image_out": u.ImageOut, "image_model": u.ImageModel,
		})
	}
	// Memory is charged to the project in batches, so it is a project-level
	// list, never a part of one run.
	var mem []usage.MemoryUsage
	_ = s.R.List(ctx, "memory_usages", database.Filter{
		Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: 50,
	}, &mem)
	memoryEvents := make([]map[string]any, 0, len(mem))
	for _, m := range mem {
		memoryEvents = append(memoryEvents, map[string]any{"id": m.ID.String(), "created_at": m.Entity.CreatedAt, "tokens": m.Tokens, "tokens_in": m.TokensIn, "cost": m.Cost})
	}
	if len(turns) == 0 {
		return helper.JSON(map[string]any{"runs": []any{}, "usage_events": usageEvents, "memory_events": memoryEvents})
	}
	oldest := turns[len(turns)-1].CreatedAt
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": spID.String()}, GreaterThan: map[string]any{"created_at": oldest.Add(-time.Second)},
		OrderBy: "created_at", Asc: true, Limit: 3000,
	}, &msgs); err != nil {
		return nil, err
	}
	people := s.participants()
	runs := make([]map[string]any, 0, len(turns))
	for i, t := range turns {
		// A run owns its room's events from its start until the next run in that
		// room begins (or now), not only until it ended: an answer to a question
		// the run asked resumes the agent outside any run of its own, and what it
		// did then belongs here, after this run.
		end, slack := time.Now().UTC(), 2*time.Second
		for j := i - 1; j >= 0; j-- {
			if turns[j].RoomID == t.RoomID {
				end, slack = turns[j].CreatedAt, 0 // the next run's own events are listed under it
				break
			}
		}
		start := t.CreatedAt
		events := []map[string]any{}
		for _, m := range msgs {
			past := m.CreatedAt.After(end.Add(slack)) || (slack == 0 && !m.CreatedAt.Before(end))
			if m.RoomID != t.RoomID || m.CreatedAt.Before(start) || past {
				continue
			}
			body := m.Body
			if r := []rune(body); len(r) > 1500 {
				body = string(r[:1500]) + "…"
			}
			who := people.get(ctx, m.SenderID)
			events = append(events, map[string]any{
				"id": m.ID.String(), "kind": m.Kind, "body": body, "created_at": m.CreatedAt,
				"sender": who["display_name"], "sender_kind": who["kind"],
			})
			if len(events) >= 200 {
				break
			}
		}
		agents := []string{}
		for _, seed := range t.Seeds {
			if id, e := identity.Parse(seed); e == nil {
				if rec, e := s.Bots.GetBot(ctx, id); e == nil {
					agents = append(agents, rec.Name)
				}
			}
		}
		runs = append(runs, map[string]any{
			"id": t.ID.String(), "room_id": t.RoomID.String(), "status": t.Status, "error": t.Error, "prompt": t.Prompt,
			"actor": people.get(ctx, t.ActorID)["handle"], "agents": agents,
			"created_at": t.CreatedAt, "started_at": t.StartedAt, "ended_at": t.EndedAt, "events": events,
			"spans": t.Spans,
		})
	}
	return helper.JSON(map[string]any{"runs": runs, "usage_events": usageEvents, "memory_events": memoryEvents})
}

// adminFiles lists every file stored in a project, across all its rooms, with
// the total size. spaces.file_list is room-scoped and member-only.
func (s *Service) adminFiles(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Limit int    `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	var files []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false}, &files); err != nil {
		return nil, err
	}
	var total int64
	for i := range files {
		total += files[i].Size
	}
	if in.Limit <= 0 || in.Limit > 500 {
		in.Limit = 200
	}
	shown := files
	if len(shown) > in.Limit {
		shown = shown[:in.Limit]
	}
	out := make([]map[string]any, 0, len(shown))
	for i := range shown {
		out = append(out, s.fileMeta(ctx, &shown[i]))
	}
	return helper.JSON(map[string]any{"files": out, "count": len(files), "total_size": total, "workspace": s.adminWorkspace(ctx, spID)})
}

// adminWorkspace lists the files on a project's computer (/workspace), the
// "Storage" people open from the project. Reading a stopped computer's files
// does not wake it. The walk is bounded (depth and count), and says so when cut.
func (s *Service) adminWorkspace(ctx context.Context, spaceID identity.ID) map[string]any {
	out := map[string]any{"available": false, "entries": []map[string]any{}, "total_size": int64(0), "truncated": false}
	id, ok := s.sandboxBotID(ctx, spaceID)
	if !ok || s.Bots == nil {
		out["note"] = "This room's computer has not been started yet."
		return out
	}
	rec, err := s.Bots.GetBot(ctx, id)
	if err != nil {
		return out
	}
	reader, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(vmm.WorkspaceReader)
	if !ok {
		out["note"] = "This machine type cannot list files while stopped."
		return out
	}
	_ = s.Bots.EnsureVM(ctx, rec)
	const maxEntries, maxDepth = 400, 4
	type dir struct {
		path  string
		depth int
	}
	var entries []map[string]any
	var total int64
	truncated := false
	queue := []dir{{"", 0}}
	for len(queue) > 0 && !truncated {
		cur := queue[0]
		queue = queue[1:]
		items, err := reader.ListWorkspace(ctx, rec.VMID, cur.path)
		if err != nil {
			if cur.path == "" {
				out["note"] = "The room's files could not be read right now."
				return out
			}
			continue
		}
		for _, it := range items {
			p := strings.TrimPrefix(cur.path+"/"+it.Name, "/")
			if len(entries) >= maxEntries {
				truncated = true
				break
			}
			entries = append(entries, map[string]any{"path": p, "type": it.Type, "size": it.Size})
			if it.Type == "dir" {
				if cur.depth+1 < maxDepth {
					queue = append(queue, dir{p, cur.depth + 1})
				} else {
					truncated = true
				}
			} else {
				total += it.Size
			}
		}
	}
	out["available"], out["entries"], out["total_size"], out["truncated"] = true, entries, total, truncated
	return out
}

// inventory is the sandbox provider's own view of what it holds, when the
// provider can report it (Modal can).
func (s *Service) inventory() (vmm.Inventory, error) {
	inv, ok := s.K.VMMFor(vmm.Type(s.sandboxVMType())).(vmm.Inventory)
	if !ok || inv == nil {
		return nil, errs.New(errs.CodeUnavailable, "this node's sandbox provider cannot list what it holds")
	}
	return inv, nil
}

// projectsByMachine maps a project computer's name ("sbx-…") to its project.
func (s *Service) projectsByMachine(ctx context.Context) map[string]map[string]any {
	out := map[string]map[string]any{}
	var all []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{}, &all); err == nil {
		for _, sp := range all {
			out["sbx-"+sp.ID.EntityString()] = map[string]any{"id": sp.ID.String(), "name": sp.Name, "owner_id": sp.OwnerID.String()}
		}
	}
	// Docker names a project's persistent workspace after the sandbox bot id.
	// Add that provider name as an alias for the same project so admin storage
	// can correlate volumes without depending on in-memory adapter state.
	var computers []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": string(bot.KindTool)}}, &computers); err == nil {
		for i := range computers {
			if !computers[i].IsSandbox() {
				continue
			}
			if project := out[computers[i].Name]; project != nil {
				out["aseman-workspace-"+computers[i].ID.String()] = project
			}
		}
	}
	return out
}

// providerSandboxRows are the machines the provider is running right now, each
// with the project it belongs to (none when no project on this node uses it).
func (s *Service) providerSandboxRows(ctx context.Context) ([]map[string]any, error) {
	inv, err := s.inventory()
	if err != nil {
		return nil, err
	}
	// A machine is the node's when the provider is running it for one of the
	// node's computers, or when it is the very sandbox a computer was made as
	// (which the node's records still say after a restart).
	byVM := map[string]string{}
	var computers []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": string(bot.KindTool)}}, &computers); err == nil {
		for i := range computers {
			if computers[i].IsSandbox() && computers[i].VMID != "" {
				byVM[computers[i].VMID] = computers[i].Name
			}
		}
	}
	rows, err := inv.Sandboxes(ctx)
	if err != nil {
		return nil, err
	}
	projects := s.projectsByMachine(ctx)
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		if r.Machine == "" {
			r.Machine = byVM[r.ID]
		}
		row := map[string]any{"id": r.ID, "name": r.Name, "machine": r.Machine, "created_at": r.CreatedAt, "started_at": r.StartedAt}
		if p := projects[r.Machine]; p != nil {
			row["project"] = p
		}
		out = append(out, row)
	}
	return out, nil
}

// adminSandboxes lists the machines the provider is running right now, each
// with the project it belongs to. One with no project is running, and billed,
// without the node using it.
func (s *Service) adminSandboxes(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	out, err := s.providerSandboxRows(ctx)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"provider": string(s.sandboxVMType()), "sandboxes": out})
}

// strayTerminateError is why a machine may not be terminated from the admin
// list: only one that no project on this node uses may be, since a project's own
// computer is stopped from its project (and its files are synced first).
func strayTerminateError(row map[string]any) error {
	if row == nil {
		return errs.NotFound("that machine is not running")
	}
	if project, ok := row["project"].(map[string]any); ok && project != nil {
		return errs.Conflict("this machine belongs to a project; stop it from the project")
	}
	return nil
}

// adminTerminateSandbox ends a machine that is running on the provider but that
// no project on this node uses (a deleted project's, or one the node lost track
// of). It is never done on its own: the machine may be another node's on the
// same provider account, so an admin decides.
func (s *Service) adminTerminateSandbox(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.ID) == "" {
		return nil, errs.InvalidArgument("machine id required")
	}
	rows, err := s.providerSandboxRows(ctx)
	if err != nil {
		return nil, err
	}
	var found map[string]any
	for _, r := range rows {
		if r["id"] == in.ID {
			found = r
		}
	}
	if err := strayTerminateError(found); err != nil {
		return nil, err
	}
	vm := s.K.VMMFor(vmm.Type(s.sandboxVMType()))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "sandbox provider unavailable")
	}
	if err := vm.DeleteVM(ctx, in.ID); err != nil {
		return nil, err
	}
	s.L.Info("sandbox terminated by an admin", "sandbox", in.ID, "machine", found["machine"])
	return helper.JSON(map[string]any{"ok": true})
}

// adminStorage lists the volumes the provider stores, each with the project
// whose files it holds. One with no project belongs to a deleted project, or
// to nothing the node knows.
func (s *Service) adminStorage(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	inv, err := s.inventory()
	if err != nil {
		return nil, err
	}
	rows, err := inv.Volumes(ctx)
	if err != nil {
		return nil, err
	}
	projects := s.projectsByMachine(ctx)
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		row := map[string]any{"id": r.ID, "name": r.Name, "created_at": r.CreatedAt}
		if p := projects[r.Name]; p != nil {
			row["project"] = p
		} else if p := projects[strings.TrimPrefix(r.Name, "aseman-")]; p != nil {
			row["project"] = p
		}
		out = append(out, row)
	}
	return helper.JSON(map[string]any{"provider": string(s.sandboxVMType()), "volumes": out})
}
