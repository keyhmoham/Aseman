package admin

import (
	"context"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// productActions are the operator dashboards (admin-only through adminGuard,
// which BuildActions wraps around every admin action).
func productActions(s *Service) []api.Action {
	out := []api.Action{}
	add := func(name, summary string, handler func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) {
		out = append(out, helper.Action{Namespace: "admin", Name: name, Summary: summary, Handler: handler})
	}
	add("stats", "Platform counters", s.stats)
	add("health", "Deploy checklist: configuration and dependencies", s.health)
	add("admins_list", "Node administrators", s.adminsList)
	add("bots_list", "Every bot on the node", s.botsList)
	add("runs_list", "Recent room work", s.runsList)
	add("node_stats", "Host resources and node telemetry", s.nodeStats)
	return out
}
func (s *Service) stats(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	r := repo.New(s.K)
	c := map[string]int64{}
	for _, model := range []string{"accounts", "spaces", "bots", "market", "room_turns"} {
		n, e := r.Count(ctx, model, database.Filter{})
		if e != nil {
			return nil, e
		}
		c[model] = n
	}
	// The directory lists only human accounts (kind "user"); count the same set.
	users, e := r.Count(ctx, "accounts", database.Filter{Equal: map[string]any{"kind": "user"}})
	if e != nil {
		return nil, e
	}
	c["users"] = users
	c["projects"] = c["spaces"]
	return helper.JSON(map[string]any{"counters": c})
}
func (s *Service) adminsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var rows []account.Account
	if e := repo.New(s.K).List(ctx, "accounts", database.Filter{}, &rows); e != nil {
		return nil, e
	}
	admins := []map[string]any{}
	for _, a := range rows {
		if a.Status == account.StatusActive && (a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"]) {
			admins = append(admins, map[string]any{"id": a.ID.String(), "handle": a.Handle, "email": a.Email})
		}
	}
	return helper.JSON(map[string]any{"admins": admins})
}
func (s *Service) botsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var rows []bot.Bot
	if e := repo.New(s.K).List(ctx, "bots", database.Filter{OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	// Agents carry their handle, backbone and fallbacks in metadata and spec yml;
	// the admin tables need them without one detail call per bot.
	type botRow struct {
		bot.Bot
		Handle         string   `json:"handle,omitempty"`
		Provider       string   `json:"provider,omitempty"`
		Model          string   `json:"model,omitempty"`
		FallbackModels []string `json:"fallback_models,omitempty"`
		OwnerHandle    string   `json:"owner_handle,omitempty"`
		Builtin        bool     `json:"builtin,omitempty"`
		Avatar         string   `json:"avatar,omitempty"`
		// What the agent is billed per minute (its own rate, else the platform's).
		PerMinute int64 `json:"per_minute,omitempty"`
	}
	r := repo.New(s.K)
	m := metasvc.Service{K: s.K, R: r}
	owners := map[string]string{}
	out := make([]botRow, 0, len(rows))
	for _, b := range rows {
		row := botRow{Bot: b}
		row.Provider, row.Model = bot.AgentBackbone(b.SpecYML)
		if b.IsBuiltinLead() {
			row.Builtin, row.Handle = true, "aseman"
		}
		if b.Kind == bot.KindAgent {
			var cost bot.CostModel
			if e := bridge.Invoke(ctx, s.K, "bots", "EffectiveCost", []any{ctx, b.ID}, &cost); e == nil {
				row.PerMinute = cost.PerMinute
			}
			if row.Model == "" {
				// Unpinned agents follow the node's default model.
				var p *llmprovider.Provider
				var mod llmprovider.Model
				if e := bridge.Invoke(ctx, s.K, "llm", "Resolve", []any{ctx, row.Provider, ""}, &p, &mod); e == nil && p != nil {
					row.Provider, row.Model = p.Name, mod.ID
				}
			}
		}
		if meta, e := m.Get(ctx, b.AccountID); e == nil && meta != nil {
			row.Avatar = helper.TreeAvatar(meta.Tree)
			if d, ok := meta.Tree["descriptor"].(map[string]any); ok {
				row.Handle, _ = d["username"].(string)
				switch fb := d["fallback_models"].(type) {
				case []any:
					for _, v := range fb {
						if id, ok := v.(string); ok && id != "" {
							row.FallbackModels = append(row.FallbackModels, id)
						}
					}
				case string:
					for _, id := range strings.Split(fb, ",") {
						if id = strings.TrimSpace(id); id != "" {
							row.FallbackModels = append(row.FallbackModels, id)
						}
					}
				}
			}
		}
		key := b.OwnerID.String()
		if _, ok := owners[key]; !ok {
			var owner account.Account
			if r.Get(ctx, "accounts", b.OwnerID, &owner) == nil {
				owners[key] = owner.Handle
			} else {
				owners[key] = ""
			}
		}
		row.OwnerHandle = owners[key]
		out = append(out, row)
	}
	return helper.JSON(map[string]any{"bots": out})
}
func (s *Service) runsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	r := repo.New(s.K)
	var turns []turn.Turn
	if e := r.List(ctx, "room_turns", database.Filter{OrderBy: "created_at", Asc: false, Limit: 1000}, &turns); e != nil {
		return nil, e
	}
	out := []map[string]any{}
	for _, t := range turns {
		for _, id := range t.Seeds {
			out = append(out, map[string]any{"kind": "turn", "id": t.ID.String(), "space_id": t.SpaceID.String(), "room_id": t.RoomID.String(), "bot_id": id, "prompt": t.Prompt, "status": t.Status, "error": t.Error, "created_at": t.CreatedAt, "updated_at": t.UpdatedAt})
		}
	}
	return helper.JSON(map[string]any{"runs": out})
}
func (s *Service) nodeStats(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	resources := map[string]any{"source": "node", "cpu_cores": runtime.NumCPU(), "process_rss_bytes": m.Sys}
	if b, e := os.ReadFile("/proc/meminfo"); e == nil {
		values := map[string]int64{}
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Fields(line)
			if len(f) > 1 {
				v, _ := strconv.ParseInt(f[1], 10, 64)
				values[strings.TrimSuffix(f[0], ":")] = v * 1024
			}
		}
		total, available := values["MemTotal"], values["MemAvailable"]
		resources["mem_total_bytes"] = total
		resources["mem_used_bytes"] = total - available
		if total > 0 {
			resources["mem_used_percent"] = float64(total-available) / float64(total) * 100
		}
	}
	if b, e := os.ReadFile("/proc/loadavg"); e == nil {
		f := strings.Fields(string(b))
		if len(f) >= 3 {
			a := []float64{}
			for _, v := range f[:3] {
				n, _ := strconv.ParseFloat(v, 64)
				a = append(a, n)
			}
			resources["load_avg"] = a
		}
	}
	if b, e := os.ReadFile("/proc/uptime"); e == nil {
		f := strings.Fields(string(b))
		if len(f) > 0 {
			n, _ := strconv.ParseFloat(f[0], 64)
			resources["host_uptime_sec"] = n
		}
	}
	var disk syscall.Statfs_t
	if e := syscall.Statfs("data", &disk); e == nil {
		total := uint64(disk.Bsize) * disk.Blocks
		free := uint64(disk.Bsize) * disk.Bavail
		resources["disk_path"] = "data"
		resources["disk_total_bytes"] = total
		resources["disk_used_bytes"] = total - free
		if total > 0 {
			resources["disk_used_percent"] = float64(total-free) / float64(total) * 100
		}
	}
	node := map[string]any{"id": s.K.NodeID().String(), "plugins": len(s.K.Registry().List()), "goroutines": runtime.NumGoroutine(), "go_version": runtime.Version()}
	return helper.JSON(map[string]any{"collected_at": time.Now().UTC(), "resources": resources, "node": node})
}
