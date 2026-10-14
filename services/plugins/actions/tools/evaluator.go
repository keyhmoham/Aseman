package tools

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// The traders leaderboard is kept by the "evaluator" tool of the platform
// admins space (deploy/tools/evaluator): it crawls traders' CoinMarketCap
// profiles, scores them and stores the scores in its own key-value store.
// Everyone signed in reads them here: the node asks the evaluator's read-only
// microtools as the caller, outside any space (the caller need not be in the
// admins space), so the evaluator can only read its own store for them.

// EvaluatorName is the name of the admins space's evaluator tool.
const EvaluatorName = "evaluator"

// evaluatorReads maps each public action to the evaluator microtool it asks.
var evaluatorReads = map[string]string{"traders_leaderboard": "leaderboard", "trader_profile": "trader_get"}

func evaluatorActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "tools", Name: "traders_leaderboard", Summary: "The traders leaderboard the admins space's evaluator keeps", Handler: s.tradersLeaderboard},
		helper.Action{Namespace: "tools", Name: "trader_profile", Summary: "One trader's reliability report from the admins space's evaluator", Handler: s.traderProfile},
	}
}

// evaluator finds the admins space's evaluator tool: a tool named
// "evaluator" whose account is a member of the admins space.
func (s *Service) evaluator(ctx context.Context) (*bot.Bot, error) {
	var raw string
	if err := bridge.Invoke(ctx, s.K, "settings", "AdminsSpace", []any{ctx}, &raw); err != nil {
		return nil, err
	}
	if strings.TrimSpace(raw) == "" {
		return nil, errs.NotFound("no admins space is chosen, so there is no traders evaluator")
	}
	space, err := identity.Parse(raw)
	if err != nil {
		return nil, err
	}
	var tools []models.Tool
	if err := s.R.List(ctx, "tool_registry", filterEq("runtime", models.RuntimeDocker), &tools); err != nil {
		return nil, err
	}
	for i := range tools {
		rec, err := s.bot(ctx, tools[i].BotID)
		if err != nil || !strings.EqualFold(strings.TrimSpace(rec.Name), EvaluatorName) {
			continue
		}
		if helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, space, identity.ID{}, false) == nil {
			return rec, nil
		}
	}
	return nil, errs.NotFound("the admins space has no evaluator tool")
}

// askEvaluator runs one of the evaluator's read microtools for the caller.
func (s *Service) askEvaluator(ctx context.Context, req *api.ActionRequest, action string, payload map[string]any) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	function, ok := evaluatorReads[action]
	if !ok {
		return nil, errs.Permission(action + " is not an evaluator read")
	}
	rec, err := s.evaluator(ctx)
	if err != nil {
		return nil, err
	}
	body, _ := json.Marshal(map[string]any{"function": function, "payload": payload})
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: req.Caller.ID.String()})
	reply, err := s.InvokeTool(ctx, rec.ID.String(), string(body))
	if err != nil {
		return nil, err
	}
	value, err := vmm.ToolResultValue(reply)
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, err.Error())
	}
	return helper.JSON(value)
}

func (s *Service) tradersLeaderboard(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Board string `json:"board"`
		Limit int    `json:"limit"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	payload := map[string]any{}
	if in.Board != "" {
		payload["board"] = in.Board
	}
	if in.Limit > 0 {
		payload["limit"] = in.Limit
	}
	return s.askEvaluator(ctx, req, "traders_leaderboard", payload)
}

func (s *Service) traderProfile(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Handle string `json:"handle"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Handle) == "" {
		return nil, errs.InvalidArgument("handle required")
	}
	return s.askEvaluator(ctx, req, "trader_profile", map[string]any{"handle": in.Handle})
}
