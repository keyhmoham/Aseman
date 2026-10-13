package spaces

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"regexp"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	bots "github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"gopkg.in/yaml.v3"
)

// Actions agents (and the people working with them) use to run a swarm in a
// space: agents write their work log and live status, ask people questions
// that people answer by id, and the lead recruits specialists into the space.
func agentActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "agent_log", Summary: "Write an agent's work log entry or live status in a room", Handler: s.agentLog},
		helper.Action{Namespace: "spaces", Name: "agent_questions", Summary: "Questions the space's agents are waiting on", Handler: s.agentQuestions},
		helper.Action{Namespace: "spaces", Name: "agent_answer", Summary: "Answer an agent's question by id (posted in the room)", Handler: s.agentAnswer},
		helper.Action{Namespace: "spaces", Name: "agent_recruit", Summary: "Create a specialist agent and add it to the space", Handler: s.agentRecruit},
	}
}

// agentLog records what an agent is doing. text becomes a work-log entry in
// the room (a log message: shown live with the agent's run, then kept as its
// history); status is the one-line live indicator ("" clears it).
func (s *Service) agentLog(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string  `json:"space"`
		Room   string  `json:"room"`
		Text   string  `json:"text"`
		Status *string `json:"status,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	ids, err := parseIDs(in.Space, in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("space and room are required")
	}
	spaceID, roomID := ids[0], ids[1]
	rec, err := s.botForMember(ctx, req.Caller.ID)
	if err != nil || rec.Kind != bot.KindAgent {
		return nil, errs.Permission("only agents write work logs")
	}
	if err := s.Can(ctx, spaceID, roomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	out := map[string]any{"ok": true}
	if in.Status != nil {
		detail := clipText(strings.TrimSpace(*in.Status), 160)
		if h := vmm.StatusFrom(ctx); h != nil {
			h(rec.Name, detail)
		} else {
			s.SetRoomActivity(ctx, roomID, rec.Name, detail)
		}
	}
	if text := strings.TrimSpace(in.Text); text != "" {
		id, err := s.storeRoomMessage(ctx, spaceID, roomID, req.Caller.ID, clipText(text, 8000), "log", "")
		if err != nil {
			return nil, err
		}
		out["message_id"] = id.String()
	}
	return helper.JSON(out)
}

// agentQuestions lists what the space's agents are waiting on people for.
func (s *Service) agentQuestions(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := s.Can(ctx, spaceID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	qs, err := s.AgentQuestions(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"questions": qs})
}

// agentAnswer answers a question by id: the answer is posted in the room as
// the person's message and handed to the waiting agent, which resumes.
func (s *Service) agentAnswer(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space      string `json:"space"`
		Room       string `json:"room,omitempty"`
		Bot        string `json:"bot"`
		QuestionID string `json:"question_id"`
		Answer     string `json:"answer"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	ids, err := parseIDs(in.Space, in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("space and bot are required")
	}
	var roomID identity.ID
	if in.Room != "" {
		if roomID, err = identity.Parse(in.Room); err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	roomID = s.ensureRoom(ctx, ids[0], roomID)
	if err := s.Can(ctx, ids[0], roomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	reply, err := s.AnswerQuestion(ctx, req.Caller.ID, ids[0], roomID, ids[1], in.QuestionID, in.Answer)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "reply": reply})
}

var handleChars = regexp.MustCompile(`[^a-z0-9]+`)

// agentRecruit creates a specialist agent on the deep agents runtime and adds
// it to the space, where people can message it and the lead (or any agent) can
// delegate to it. Inside a run the person who started the run owns and pays for
// it; it uses the recruiting agent's model unless one is given.
func (s *Service) agentRecruit(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space        string             `json:"space"`
		Room         string             `json:"room,omitempty"`
		Name         string             `json:"name"`
		Description  string             `json:"description"`
		Instructions string             `json:"instructions"`
		Provider     string             `json:"provider,omitempty"`
		Model        string             `json:"model,omitempty"`
		Skills       []bots.SkillConfig `json:"skills,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Instructions) == "" {
		return nil, errs.InvalidArgument("a recruit needs a name and instructions")
	}
	owner := s.payer(ctx, req.Caller.ID)
	if err := s.Can(ctx, spaceID, identity.ID{}, owner, permission.SpaceManageBots); err != nil {
		return nil, err
	}
	if recruiter, err := s.botForMember(ctx, req.Caller.ID); err == nil && in.Model == "" {
		var spec struct {
			Provider string `yaml:"provider"`
			Model    string `yaml:"model"`
		}
		if yaml.Unmarshal([]byte(recruiter.SpecYML), &spec) == nil {
			in.Provider, in.Model = spec.Provider, spec.Model
		}
	}
	slug := strings.Trim(handleChars.ReplaceAllString(strings.ToLower(in.Name), "-"), "-")
	if slug == "" {
		slug = "agent"
	}
	suffix := make([]byte, 2)
	_, _ = rand.Read(suffix)
	name := clipText(slug, 40) + "-" + hex.EncodeToString(suffix)
	rec, err := s.Bots.CreateBot(helper.WithActor(ctx, owner), owner, bots.CreateBotRequest{
		Name: name, Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents,
		Description: in.Description, Instructions: in.Instructions,
		Provider: in.Provider, Model: in.Model, Skills: in.Skills,
	})
	if err != nil {
		return nil, err
	}
	if err := s.AddBot(ctx, owner, spaceID, identity.ID{}, rec.AccountID); err != nil {
		return nil, err
	}
	s.L.Info("agent recruited", "space", spaceID.String(), "bot", rec.ID.String(), "name", rec.Name, "by", req.Caller.ID.String())
	return helper.JSON(map[string]any{"bot_id": rec.ID.String(), "account_id": rec.AccountID.String(), "name": rec.Name, "description": in.Description})
}
