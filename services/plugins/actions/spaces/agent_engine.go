package spaces

// The agentic engine: which runtime runs every agent turn on the node.
//
//	deepagents (the default) — LangChain Deep Agents on LangGraph, models
//	  through the platform's metered LLM gateway.
//	opencode — the OpenCode CLI, headless, on OpenCode's own gateway with a
//	  free model chosen for the role. Platform providers are not used.
//	deepseek — DeepSeek Harness (dsh), headless, with its own agentic
//	  modules (loop, memory, swarm of subagents, Agent Teams, planning,
//	  goals, workflows) wired to the platform: the agent's model on the
//	  metered LLM gateway, the space through the Aseman MCP bridge.
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
	// AgentEngineDeepSeek is headless DeepSeek Harness (dsh).
	AgentEngineDeepSeek = "deepseek"
)

// agentEngines are the engines a node can run, in the order the admin sees them.
var agentEngines = []string{AgentEngineDeepAgents, AgentEngineOpenCode, AgentEngineDeepSeek}

// AgentEngineSetting is the node's agentic engine.
type AgentEngineSetting struct {
	ID        string    `db:"id" json:"-"`
	Engine    string    `db:"engine" json:"engine"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

func (s *Service) agentEngineRowID() string { return s.K.NodeID().String() + "agentengine" }

func normalizeAgentEngine(engine string) (string, error) {
	switch engine {
	case AgentEngineDeepAgents, AgentEngineOpenCode, AgentEngineDeepSeek:
		return engine, nil
	default:
		return "", errs.InvalidArgument(`agent_engine_set needs engine "deepagents", "opencode" or "deepseek"`)
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
		{"platform": "Personal Aseman (notes / Talk)", "opencode": "free OpenCode model + person-scoped MCP gateway (same space tools as room turns)"},
		{"platform": "Agent team", "opencode": "OpenCode agents (primary for the agent on the turn, subagents for teammates)"},
		{"platform": "Task handoff", "opencode": "OpenCode's task tool, and opencode run --agent for the teammate"},
		{"platform": "Swarm", "opencode": "Parallel opencode run processes, one per task, at the same time"},
		{"platform": "App generation", "opencode": "The aseman-app-builder subagent, through platform file tools, then appui_publish"},
		{"platform": "Planning", "opencode": "OpenCode's todowrite"},
		{"platform": "Questions to people", "opencode": "ask_user on the turn's tool bridge; the session waits"},
		{"platform": "Messaging, sandbox, apps", "opencode": "Named MCP space tools (send_message, list_space_tools, call_space_tool, …) on the turn gateway — same actions as Deep Agents"},
		{"platform": "Models", "opencode": "A free model on OpenCode's own gateway, chosen for the role"},
	}
}

// deepSeekMapping is how platform mechanisms land on DeepSeek Harness. The
// harness brings its own memory and swarm; the platform wires them in.
func deepSeekMapping() []map[string]string {
	return []map[string]string{
		{"platform": "Agent turn", "deepseek": "dsh --profile headless --json with an Aseman patch overlay; one dsh Session per agent per thread"},
		{"platform": "Agentic loop", "deepseek": "dsh's own agent loop, with its guard, compaction and retry plugins"},
		{"platform": "Models", "deepseek": "The agent's own provider and model through the platform's metered LLM gateway (or the engine's own DeepSeek key)"},
		{"platform": "Personal Aseman (notes / Talk)", "deepseek": "The assistant's platform model + person-scoped Aseman MCP tools; its own memory per person"},
		{"platform": "Memory", "deepseek": "DeepSeek Harness's own: the aseman-memory dsh plugin (notes, search, a journal of every turn) per space and agent, loaded by dsh's instruction loader"},
		{"platform": "Swarm", "deepseek": "DeepSeek Harness's own: parallel subagents (subagent, wait_agent, send_message, list_agents), shown in the agent's work log"},
		{"platform": "Agent team", "deepseek": "dsh Agent Teams task board for leads (dsh 0.2.2+), with the space's Aseman agents as teammates"},
		{"platform": "Subagents", "deepseek": "dsh subagent / subagent_fork (in-process children)"},
		{"platform": "Task handoff / dispatch", "deepseek": "delegate_task: a room task to another Aseman agent, whose own turn answers"},
		{"platform": "Planning & workflow", "deepseek": "dsh todo_write, plan mode, goals and the workflow tool; todos go to the work log"},
		{"platform": "Questions to people", "deepseek": "ask_user on the Aseman bridge; the question waits in Aseman and the dsh Session resumes with the answer"},
		{"platform": "Creator mode / plugin creation", "deepseek": "create_app / create_plugin → Aseman's on-demand app generation (appui_create, appui_publish)"},
		{"platform": "Messaging, sandbox, apps, timeline, Code Mode", "deepseek": "Named tools on the Aseman MCP bridge, on the turn gateway — the same actions as Deep Agents"},
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
		"engines":    agentEngines,
		"mapping":    agentEngineMapping(),
		// Each CLI engine's own mapping; rows are {platform, how}.
		"mappings": map[string][]map[string]string{
			AgentEngineOpenCode: howRows(agentEngineMapping(), AgentEngineOpenCode),
			AgentEngineDeepSeek: howRows(deepSeekMapping(), AgentEngineDeepSeek),
		},
		// Present so the panel can say the programmer switch is untouched.
		"programmer": "spaces.opencode_get",
	}
	switch row.Engine {
	case AgentEngineDeepSeek:
		view["llm"] = "platform"
		view["status"] = "DeepSeek Harness runs every agent turn and personal Aseman with its own memory and swarm, on the agents' platform models (metered), with the space's tools on the Aseman MCP bridge. The programmer OpenCode switch (who builds apps) is unchanged."
	case AgentEngineOpenCode:
		view["llm"] = "opencode-free"
		view["status"] = "OpenCode CLI runs every agent turn and personal Aseman on its own free-model gateway, with MCP space tools on the turn/person gateway (same actions Deep Agents uses in a space). The programmer OpenCode switch (who builds apps) is unchanged."
	default:
		view["llm"] = "platform"
		view["status"] = "Deep Agents runs every agent turn. Personal Aseman uses the chat assistant's platform model. The programmer OpenCode switch still decides who writes code."
	}
	return view, nil
}

// howRows is a mapping with each row's engine column also under "how".
func howRows(rows []map[string]string, engine string) []map[string]string {
	out := make([]map[string]string, 0, len(rows))
	for _, row := range rows {
		out = append(out, map[string]string{"platform": row["platform"], "how": row[engine], engine: row[engine]})
	}
	return out
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
		helper.Action{Namespace: "spaces", Name: "agent_engine_set", Summary: "Admin: switch the agentic engine (deepagents, opencode or deepseek)",
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
