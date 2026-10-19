// Package usages implements the usage namespace: per-request LLM token
// consumption accounting. Usage rows are recorded by the bots service as agents
// answer, and queried here — rolled up per space, per room chat and per agent.
package usages

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Recorder is the write side of the usage ledger, implemented by the usages
// service and consumed by the bots service.
type Recorder interface {
	Record(ctx context.Context, u *usage.Usage) error
}

// SpacesPort is the subset of the spaces service the usage queries need: they
// only list usage the caller may see (must be a member of the space).
type SpacesPort interface {
	// CanView reports whether [user] is a member of the space.
	MemberOf(ctx context.Context, spaceID, user identity.ID) (bool, error)
}

// Service manages the usage ledger.
type Service struct {
	K      api.Kernel
	R      *repo.Repo
	L      *logger.Logger
	Spaces SpacesPort
}

// NewService builds the usage service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("usage")}
}

// Record appends one usage event to the ledger.
func (s *Service) Record(ctx context.Context, u *usage.Usage) error {
	if u.SpaceID.IsZero() {
		return errs.InvalidArgument("usage space required")
	}
	if u.TokensIn <= 0 && u.TokensOut <= 0 && u.Images <= 0 && u.DecisionIn <= 0 && u.DecisionOut <= 0 {
		return nil // nothing consumed; skip the noise
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	u.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "usages", id, u); err != nil {
		return errs.Wrap(errs.CodeInternal, err, "record usage")
	}
	return nil
}

// RecordMemory appends one settlement of a project's memory use.
func (s *Service) RecordMemory(ctx context.Context, spaceID identity.ID, tokens, tokensIn, cost int64) error {
	if spaceID.IsZero() || (tokens <= 0 && cost <= 0) {
		return nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	m := &usage.MemoryUsage{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: spaceID, Tokens: tokens, TokensIn: tokensIn, Cost: cost}
	if err := s.R.CreateID(ctx, "memory_usages", id, m); err != nil {
		return errs.Wrap(errs.CodeInternal, err, "record memory usage")
	}
	return nil
}

// List returns usage events, optionally filtered by space/room/bot, newest
// first.
func (s *Service) List(ctx context.Context, spaceID, roomID, botID identity.ID, limit, offset int) ([]usage.Usage, error) {
	if spaceID.IsZero() {
		return nil, errs.InvalidArgument("space required")
	}
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	filter := database.Filter{
		Equal:   map[string]any{"space_id": spaceID.String()},
		OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}
	if !roomID.IsZero() {
		filter.Equal["room_id"] = roomID.String()
	}
	if !botID.IsZero() {
		filter.Equal["bot_id"] = botID.String()
	}
	var out []usage.Usage
	if err := s.R.List(ctx, "usages", filter, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Summary rolls a space's usage up per room and per bot (agent), newest events
// first. Each rollup carries the totals and the most recent activity time.
func (s *Service) Summary(ctx context.Context, spaceID identity.ID, limit int) (map[string]any, error) {
	all, err := s.List(ctx, spaceID, identity.ID{}, identity.ID{}, limit, 0)
	if err != nil {
		return nil, err
	}
	byRoom := map[string]*rollup{}
	byBot := map[string]*rollup{}
	for i := range all {
		u := &all[i]
		roomKey := u.RoomID.String()
		if u.RoomID.IsZero() {
			roomKey = "_"
		}
		if _, ok := byRoom[roomKey]; !ok {
			byRoom[roomKey] = &rollup{Key: roomKey, Label: roomKey, LastAt: u.CreatedAt()}
		}
		byRoom[roomKey].Add(u)
		botKey := u.BotID.String()
		if botKey == "" {
			botKey = u.BotName
		}
		if botKey == "" {
			botKey = "_"
		}
		if _, ok := byBot[botKey]; !ok {
			byBot[botKey] = &rollup{Key: botKey, Label: u.BotName, LastAt: u.CreatedAt()}
		}
		byBot[botKey].Add(u)
	}
	return map[string]any{
		"space_id":   spaceID.String(),
		"rooms":      sortRollups(byRoom),
		"agents":     sortRollups(byBot),
		"total_in":   total(all, true),
		"total_out":  total(all, false),
		"total_cost": totalCost(all),
	}, nil
}

type rollup struct {
	Key       string    `json:"key"`
	Label     string    `json:"label"`
	Requests  int       `json:"requests"`
	TokensIn  int64     `json:"tokens_in"`
	TokensOut int64     `json:"tokens_out"`
	Images    int64     `json:"images"`
	Cost      int64     `json:"cost"`
	LastAt    time.Time `json:"last_at"`
}

func (r *rollup) Add(u *usage.Usage) {
	r.Requests++
	r.TokensIn += u.TokensIn
	r.TokensOut += u.TokensOut
	r.Images += u.Images
	r.Cost += u.Cost
	if u.CreatedAt().After(r.LastAt) {
		r.LastAt = u.CreatedAt()
	}
}

func sortRollups(m map[string]*rollup) []*rollup {
	out := make([]*rollup, 0, len(m))
	for _, r := range m {
		out = append(out, r)
	}
	// Stable ordering: most recent activity first, then by key.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && (out[j].LastAt.After(out[j-1].LastAt) ||
			(out[j].LastAt.Equal(out[j-1].LastAt) && out[j].Key < out[j-1].Key)); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func total(all []usage.Usage, in bool) int64 {
	var t int64
	for i := range all {
		if in {
			t += all[i].TokensIn
		} else {
			t += all[i].TokensOut
		}
	}
	return t
}

func totalCost(all []usage.Usage) int64 {
	var t int64
	for i := range all {
		t += all[i].Cost
	}
	return t
}

// BuildActions assembles the usage namespace actions.
func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		&usageListAction{s: s}, &usageSummaryAction{s: s},
	}, projectionActions(s)...)
}

// canViewSpace guards read actions: the caller must be a member of the space.
func (s *Service) canViewSpace(ctx context.Context, caller, spaceID identity.ID) error {
	if spaceID.IsZero() {
		return errs.InvalidArgument("space required")
	}
	if s.Spaces == nil {
		return errs.New(errs.CodeUnavailable, "usage queries not wired")
	}
	if ok, err := s.Spaces.MemberOf(ctx, spaceID, caller); err != nil {
		return err
	} else if !ok {
		return errs.Permission("not a member of the space")
	}
	return nil
}

type usageSummaryAction struct{ s *Service }

func (a *usageSummaryAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "usage", Name: "summary", Summary: "LLM token usage rolled up per room and per agent"}
}
func (a *usageSummaryAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Limit int    `json:"limit"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := a.s.canViewSpace(ctx, req.Caller.ID, spaceID); err != nil {
		return nil, err
	}
	sum, err := a.s.Summary(ctx, spaceID, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(sum)
}

type usageListAction struct{ s *Service }

func (a *usageListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "usage", Name: "list", Summary: "List LLM token usage events of a space"}
}
func (a *usageListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room,omitempty"`
		Bot    string `json:"bot,omitempty"`
		Limit  int    `json:"limit"`
		Offset int    `json:"offset"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := a.s.canViewSpace(ctx, req.Caller.ID, spaceID); err != nil {
		return nil, err
	}
	var roomID, botID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if in.Bot != "" {
		botID, err = identity.Parse(in.Bot)
		if err != nil {
			return nil, errs.InvalidArgument("invalid bot id")
		}
	}
	rows, err := a.s.List(ctx, spaceID, roomID, botID, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"usages": rows})
}
