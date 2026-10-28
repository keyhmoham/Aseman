package proactive

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "proactive", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(helper.WithActor(ctx, req.Caller.ID), req)
		}}
	}
	return []api.Action{
		a("tasks_list", "My Tasks: what needs me, what agents suggest, what they work on", s.tasksList),
		a("task_start", "Start a task (a suggestion, a mail that needs me, or one that failed)", s.taskStart),
		a("task_answer", "Answer a task that needs my input; it goes back to Working", s.taskAnswer),
		a("task_hide", "Hide a suggestion", s.taskSet("hidden")),
		a("task_resolve", "Check a task off; it folds into Resolved", s.taskSet("resolved")),
		a("task_reopen", "Reopen a resolved task", s.taskSet("ready_for_review")),
		a("suggestion_latest", "The newest suggestion, shown above Chat's composer", s.suggestionLatest),
		a("brief_today", "Today's morning brief: made once a day after my first, then returned as it is", s.briefToday),
		a("brief_now", "Make my brief again now", s.briefNow),
		a("brief_start", "Hand an email from my brief to my lead as a task", s.briefStart),
		a("triage", "Sort my recent mail into what needs me and what can wait", s.triage),
		a("first_day", "The first-day greeting in my home project (runs once)", s.firstDay),
		a("settings_get", "My background research and brief settings", s.settingsGet),
		a("settings_set", "Turn background research on or off, how often, and the brief", s.settingsSet),
		a("research_now", "Run a background check-in now", s.researchNow),
	}
}

func (s *Service) tasksList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space,omitempty"`
		Hidden bool   `json:"hidden,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rows, err := s.Tasks(ctx, req.Caller.ID, in.Space, in.Hidden)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"tasks": rows})
}

type taskBody struct {
	ID   string `json:"id"`
	Text string `json:"text,omitempty"`
}

func (s *Service) taskStart(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in taskBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	t, err := s.Start(ctx, req.Caller.ID, in.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"task": t})
}

func (s *Service) taskAnswer(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in taskBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	t, err := s.Answer(ctx, req.Caller.ID, in.ID, in.Text)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"task": t})
}

func (s *Service) taskSet(status string) func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
	return func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
		var in taskBody
		if err := helper.Decode(req, &in); err != nil {
			return nil, err
		}
		t, err := s.SetStatus(ctx, req.Caller.ID, in.ID, status)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"task": t})
	}
}

func (s *Service) suggestionLatest(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	rows, err := s.Tasks(ctx, req.Caller.ID, "", false)
	if err != nil {
		return nil, err
	}
	for _, t := range rows {
		if t.Status == "suggested" {
			return helper.JSON(map[string]any{"task": t})
		}
	}
	return helper.JSON(map[string]any{"task": nil})
}

type tzBody struct {
	Timezone string `json:"timezone,omitempty"`
}

func (s *Service) briefToday(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in tzBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	b, ok, err := s.BriefToday(ctx, req.Caller.ID, in.Timezone, false)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"brief": b, "available": ok})
}

func (s *Service) briefNow(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in tzBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	b, _, err := s.BriefToday(ctx, req.Caller.ID, in.Timezone, true)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"brief": b, "available": true})
}

func (s *Service) briefStart(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Mail string `json:"mail"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	t, err := s.StartFromMail(ctx, req.Caller.ID, in.Mail)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"task": t})
}

func (s *Service) triage(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Query string `json:"query,omitempty"`
		Max   int    `json:"max,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	verdicts, undecided, err := s.Triage(ctx, req.Caller.ID, in.Query, in.Max)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"verdicts": verdicts, "undecided": undecided})
}

func (s *Service) firstDay(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in tzBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	out, err := s.FirstDay(ctx, req.Caller.ID, in.Timezone)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

func (s *Service) settingsGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in tzBody
	_ = helper.Decode(req, &in)
	return helper.JSON(map[string]any{"settings": s.person(ctx, req.Caller.ID, in.Timezone)})
}

func (s *Service) settingsSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Research      bool  `json:"research"`
		IntervalHours int64 `json:"interval_hours,omitempty"`
		BriefOff      *bool `json:"brief_off,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := s.SetResearch(ctx, req.Caller.ID, in.Research, in.IntervalHours, in.BriefOff)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"settings": p})
}

func (s *Service) researchNow(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	result, err := s.Research(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"result": result})
}
