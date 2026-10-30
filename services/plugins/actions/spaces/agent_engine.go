package spaces

// The agentic engine: which runtime runs every agent turn on the node.
//
//	deepagents (the default) — LangChain Deep Agents on LangGraph, models
//	  through the platform's metered LLM gateway.
//	opencode — the OpenCode CLI, headless, on OpenCode's own gateway with a
//	  free model chosen for the role. Platform providers are not used.
//
// Admins switch it (Admin → AI → Agentic engine). The next turn reads it;
// nothing is restarted. It does not touch the programmer OpenCode switch
// (opencode.go): that one only decides who writes code inside a Deep Agents
// turn (appui_create / opencode_run, the sandbox's /etc/opencode, the
// metered gateway).

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

const (
	agentEngineTable = "spaces_agent_engine"

	// AgentEngineDeepAgents is the LangGraph runtime (the default).
	AgentEngineDeepAgents = "deepagents"
	// AgentEngineOpenCode is the headless OpenCode CLI.
	AgentEngineOpenCode = "opencode"
)

// AgentEngineSetting is the node's agentic engine.
type AgentEngineSetting struct {
	ID        string    `db:"id" json:"-"`
	Engine    string    `db:"engine" json:"engine"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

func (s *Service) agentEngineRowID() string { return s.K.NodeID().String() + "agentengine" }

func normalizeAgentEngine(engine string) (string, error) {
	switch engine {
	case AgentEngineDeepAgents, AgentEngineOpenCode:
		return engine, nil
	default:
		return "", errs.InvalidArgument(`agent_engine_set needs engine "deepagents" or "opencode"`)
	}
}

// AgentEngine returns the engine that runs the next turn (deepagents when
// never set). The runtime reads this on every turn, so a change applies
// immediately.
func (s *Service) AgentEngine(ctx context.Context) (string, error) {
	row, err := s.agentEngine(ctx)
	if err != nil {
		return "", err
	}
	if row.Engine == "" {
		return AgentEngineDeepAgents, nil
	}
	return row.Engine, nil
}

func (s *Service) agentEngine(ctx context.Context) (*AgentEngineSetting, error) {
	var row AgentEngineSetting
	err := s.R.GetString(ctx, agentEngineTable, s.agentEngineRowID(), &row)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &AgentEngineSetting{ID: s.agentEngineRowID(), Engine: AgentEngineDeepAgents}, nil
	}
	if err != nil {
		return nil, err
	}
	if row.Engine == "" {
		row.Engine = AgentEngineDeepAgents
	}
	return &row, nil
}

// SetAgentEngine switches the engine for the whole node.
func (s *Service) SetAgentEngine(ctx context.Context, engine string) (*AgentEngineSetting, error) {
	engine, err := normalizeAgentEngine(engine)
	if err != nil {
		return nil, err
	}
	row, err := s.agentEngine(ctx)
	if err != nil {
		return nil, err
	}
	creating := row.UpdatedAt.IsZero()
	row.Engine, row.UpdatedAt = engine, time.Now().UTC()
	if creating {
		err = s.R.DB.Create(ctx, agentEngineTable, row.ID, row)
	} else {
		err = s.R.DB.Update(ctx, agentEngineTable, row.ID, row)
	}
	if err != nil {
		return nil, err
	}
	return row, nil
}

// agentEngineMapping is how platform mechanisms land on OpenCode's CLI when
// that engine is selected. The programmer OpenCode path is not in this list.
func agentEngineMapping() []map[string]string {
	return []map[string]string{
		{"platform": "Agent turn", "opencode": "opencode run --format json --auto, one session per agent per room"},
		{"platform": "Agent team", "opencode": "OpenCode agents (primary for the agent on the turn, subagents for teammates)"},
		{"platform": "Task handoff", "opencode": "OpenCode's task tool, and opencode run --agent for the teammate"},
		{"platform": "Swarm", "opencode": "Parallel opencode run processes, one per task, at the same time"},
		{"platform": "App generation", "opencode": "The aseman-app-builder subagent, through platform file tools, then appui_publish"},
		{"platform": "Planning", "opencode": "OpenCode's todowrite"},
		{"platform": "Questions to people", "opencode": "ask_user on the turn's tool bridge; the session waits"},
		{"platform": "Messaging, sandbox, apps", "opencode": "Platform actions on the turn gateway, never the LLM proxy"},
		{"platform": "Models", "opencode": "A free model on OpenCode's own gateway, chosen for the role"},
	}
}

func (s *Service) agentEngineView(ctx context.Context) (map[string]any, error) {
	row, err := s.agentEngine(ctx)
	if err != nil {
		return nil, err
	}
	view := map[string]any{
		"engine":     row.Engine,
		"updated_at": row.UpdatedAt,
		"active":     true,
		"engines":    []string{AgentEngineDeepAgents, AgentEngineOpenCode},
		"mapping":    agentEngineMapping(),
		// Present so the panel can say the programmer switch is untouched.
		"programmer": "spaces.opencode_get",
	}
	switch row.Engine {
	case AgentEngineOpenCode:
		view["llm"] = "opencode-free"
		view["status"] = "OpenCode CLI runs every agent turn on its own free-model gateway. Platform LLM providers are not used. The programmer OpenCode switch (who builds apps) is unchanged."
	default:
		view["llm"] = "platform"
		view["status"] = "Deep Agents runs every agent turn. Models come from the platform LLM gateway. The programmer OpenCode switch still decides who writes code."
	}
	return view, nil
}

func agentEngineActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "agent_engine_get", Summary: "Admin: which runtime runs agent turns",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
					return nil, err
				}
				view, err := s.agentEngineView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "spaces", Name: "agent_engine_set", Summary: "Admin: switch the agentic engine (deepagents or opencode)",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
					return nil, err
				}
				var in struct {
					Engine string `json:"engine"`
				}
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if _, err := s.SetAgentEngine(ctx, in.Engine); err != nil {
					return nil, err
				}
				view, err := s.agentEngineView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}
