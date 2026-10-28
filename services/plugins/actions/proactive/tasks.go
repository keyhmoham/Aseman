package proactive

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Tasks are what a person sees in one place: what needs them (answered
// right there), what agents suggest from their background research, and
// what agents are working on. A started task runs as a turn of the lead in
// its room and follows that turn: Working, then Ready for review or Needs
// input with the agent's next step, or Failed with the reason (and Try
// again when running it again can help). Checked off, it folds into Resolved.

// Tasks lists a person's tasks, newest first; space narrows it.
func (s *Service) Tasks(ctx context.Context, owner identity.ID, space string, includeHidden bool) ([]pm.Task, error) {
	f := database.Filter{Equal: map[string]any{"owner_id": owner.String()}, OrderBy: "updated_at", Limit: 300}
	if space != "" {
		f.Equal["space_id"] = space
	}
	var rows []pm.Task
	if err := s.R.List(ctx, "tasks", f, &rows); err != nil {
		return nil, err
	}
	if includeHidden {
		return rows, nil
	}
	out := rows[:0]
	for _, t := range rows {
		if t.Status != pm.StatusHidden {
			out = append(out, t)
		}
	}
	return out, nil
}

// task loads one of the owner's tasks.
func (s *Service) task(ctx context.Context, owner identity.ID, id string) (*pm.Task, error) {
	tid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.InvalidArgument("invalid task")
	}
	var t pm.Task
	if err := s.R.Get(ctx, "tasks", tid, &t); err != nil {
		return nil, err
	}
	if t.OwnerID != owner.String() {
		return nil, errs.NotFound("task")
	}
	return &t, nil
}

func (s *Service) save(ctx context.Context, t *pm.Task) error {
	t.UpdatedAt = s.now().UTC()
	return s.R.Update(ctx, "tasks", t.ID, t)
}

// AddTask records a new task for a person.
func (s *Service) AddTask(ctx context.Context, t *pm.Task) (*pm.Task, error) {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	t.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	t.Title, t.Detail, t.Reason = clip(t.Title, 200), clip(t.Detail, 2000), clip(t.Reason, 300)
	if t.Color == "" && t.RoomID != "" && s.Spaces != nil {
		if rid, err := identity.Parse(t.RoomID); err == nil {
			if room, err := s.Spaces.GetRoom(ctx, rid); err == nil && room != nil {
				t.Color = room.Color
			}
		}
	}
	if err := s.R.CreateID(ctx, "tasks", id, t); err != nil {
		return nil, err
	}
	return t, nil
}

// prompt is what the lead is told when a task starts.
func taskPrompt(t *pm.Task) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[task %s] The person started this task from their Tasks: %s\n", t.ID.String(), t.Title)
	if t.Detail != "" {
		b.WriteString("What it is: " + t.Detail + "\n")
	}
	if t.Reason != "" {
		b.WriteString("Why: " + t.Reason + "\n")
	}
	if strings.HasPrefix(t.Source, "mail:") {
		b.WriteString("It is about the email " + strings.TrimPrefix(t.Source, "mail:") + ": read it with gmail_read first.\n")
	}
	b.WriteString("Do it. When you need the person, call task_update with status needs_input and the question; " +
		"when it is done, call task_update with status ready_for_review and a one-line summary. " +
		"Anything that sends, pays, signs or deletes will ask them first.")
	return b.String()
}

// Start begins a suggested, needs-you or failed task.
func (s *Service) Start(ctx context.Context, owner identity.ID, id string) (*pm.Task, error) {
	t, err := s.task(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	switch t.Status {
	case pm.StatusSuggested, pm.StatusFailed, pm.StatusHidden:
	case pm.StatusWorking:
		return t, nil
	default:
		if t.Kind != pm.KindNeedsYou {
			return nil, errs.Conflict("this task is " + t.Status)
		}
	}
	space, err := identity.Parse(t.SpaceID)
	if err != nil {
		home, herr := s.Spaces.HomeSpace(ctx, owner)
		if herr != nil {
			return nil, herr
		}
		space, t.SpaceID = home.ID, home.ID.String()
	}
	room, _ := identity.Parse(t.RoomID)
	attempt := s.now().UnixNano()
	tr, err := s.Spaces.AskLead(ctx, owner, space, room, fmt.Sprintf("task-%s-%d", t.ID.String(), attempt), "▶ "+t.Title, taskPrompt(t), false)
	if err != nil {
		return nil, err
	}
	t.Status, t.TurnID, t.MessageID, t.Error, t.Retryable, t.Summary = pm.StatusWorking, tr.ID.String(), tr.MessageID, "", false, ""
	if t.RoomID == "" {
		t.RoomID = tr.RoomID.String()
	}
	t.StartedAt = s.now().UTC()
	if t.Kind == pm.KindSuggestion || t.Kind == pm.KindNeedsYou {
		t.Kind = pm.KindWork
	}
	return t, s.save(ctx, t)
}

// Answer gives a task that needs input the person's answer and sets it
// working again.
func (s *Service) Answer(ctx context.Context, owner identity.ID, id, text string) (*pm.Task, error) {
	t, err := s.task(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, errs.InvalidArgument("an answer is required")
	}
	space, _ := identity.Parse(t.SpaceID)
	room, _ := identity.Parse(t.RoomID)
	prompt := fmt.Sprintf("[task %s] The person answered about \"%s\": %s", t.ID.String(), t.Title, text)
	tr, err := s.Spaces.AskLead(ctx, owner, space, room, fmt.Sprintf("task-%s-answer-%d", t.ID.String(), s.now().UnixNano()), text, prompt, false)
	if err != nil {
		return nil, err
	}
	t.Status, t.TurnID, t.Summary = pm.StatusWorking, tr.ID.String(), ""
	return t, s.save(ctx, t)
}

// SetStatus hides, resolves or reopens a task.
func (s *Service) SetStatus(ctx context.Context, owner identity.ID, id, status string) (*pm.Task, error) {
	t, err := s.task(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	switch status {
	case pm.StatusHidden, pm.StatusResolved:
		if status == pm.StatusResolved {
			t.DoneAt = s.now().UTC()
		}
	case pm.StatusReview:
		if t.Status != pm.StatusResolved {
			return nil, errs.InvalidArgument("only a resolved task reopens")
		}
	default:
		return nil, errs.InvalidArgument("status is hidden, resolved or ready_for_review")
	}
	t.Status = status
	return t, s.save(ctx, t)
}

// follow moves working tasks along as their turns end.
func (s *Service) follow(ctx context.Context) {
	var rows []pm.Task
	if err := s.R.List(ctx, "tasks", database.Filter{Equal: map[string]any{"status": pm.StatusWorking}, Limit: 500}, &rows); err != nil {
		return
	}
	for i := range rows {
		t := &rows[i]
		if t.TurnID == "" {
			continue
		}
		var tr turn.Turn
		if err := s.R.DB.Get(ctx, "room_turns", t.TurnID, &tr); err != nil {
			continue
		}
		switch tr.Status {
		case "done":
			// The agent's task_update may have moved it already; otherwise
			// it is ready for the person to look at.
			var cur pm.Task
			if s.R.Get(ctx, "tasks", t.ID, &cur) == nil && cur.Status == pm.StatusWorking {
				cur.Status, cur.DoneAt = pm.StatusReview, s.now().UTC()
				if cur.Summary == "" {
					cur.Summary = "Finished. Open the conversation to review."
				}
				_ = s.save(ctx, &cur)
				s.notify(ctx, &cur, "Ready for review: "+cur.Title, cur.Summary)
			}
		case "failed", "cancelled", "blocked":
			t.Status, t.Retryable = pm.StatusFailed, tr.Status != "blocked"
			t.Error = failureReason(tr)
			_ = s.save(ctx, t)
			s.notify(ctx, t, "Couldn't finish: "+t.Title, t.Error)
		}
	}
}

func failureReason(tr turn.Turn) string {
	switch {
	case tr.Status == "cancelled":
		return "It was stopped."
	case tr.Status == "blocked":
		return "It is blocked: " + clip(tr.Error, 200)
	case strings.Contains(strings.ToLower(tr.Error), "budget") || strings.Contains(strings.ToLower(tr.Error), "wallet") || strings.Contains(strings.ToLower(tr.Error), "fund"):
		return "It stopped over money: " + clip(tr.Error, 200)
	}
	return "The agent ran into a problem and couldn't finish."
}

func (s *Service) notify(ctx context.Context, t *pm.Task, title, body string) {
	if s.Users == nil {
		return
	}
	owner, err := identity.Parse(t.OwnerID)
	if err != nil {
		return
	}
	s.Users.Push(ctx, []identity.ID{owner}, PushNote{Title: clip(title, 120), Body: clip(body, 180), Kind: "task",
		Space: t.SpaceID, Room: t.RoomID, Collapse: "task-" + t.ID.String()})
}

// ── agent tools ─────────────────────────────────────────────────────────────

// AvailableTools: agents working for a person may suggest tasks and report
// on the one they work on.
func (s *Service) AvailableTools(ctx context.Context, actor, space string) ([]string, error) {
	if !s.isPerson(ctx, actor) {
		return []string{}, nil
	}
	return []string{"offer_task", "task_update"}, nil
}

// AgentTool serves offer_task and task_update.
func (s *Service) AgentTool(ctx context.Context, call gate.ToolCall) (string, error) {
	var in struct {
		Title   string `json:"title"`
		Detail  string `json:"detail"`
		Reason  string `json:"reason"`
		Task    string `json:"task"`
		Status  string `json:"status"`
		Summary string `json:"summary"`
	}
	_ = json.Unmarshal([]byte(call.Args), &in)
	owner, err := identity.Parse(call.ActorID)
	if err != nil || !s.isPerson(ctx, call.ActorID) {
		return "", errs.Permission("tasks belong to a person; this run has none")
	}
	switch call.Tool {
	case "offer_task":
		if strings.TrimSpace(in.Title) == "" {
			return "", errs.InvalidArgument("offer_task needs a title")
		}
		if dup := s.duplicateSuggestion(ctx, owner, in.Title); dup {
			return "Already suggested; not repeated.", nil
		}
		t, err := s.AddTask(ctx, &pm.Task{OwnerID: owner.String(), SpaceID: call.SpaceID, RoomID: call.RoomID, Kind: pm.KindSuggestion,
			Status: pm.StatusSuggested, Title: in.Title, Detail: in.Detail, Reason: in.Reason, Source: "agent:" + call.AgentName})
		if err != nil {
			return "", err
		}
		s.notify(ctx, t, "Suggested: "+t.Title, t.Reason)
		return "Suggested to the person as a task (" + t.ID.String() + "). They decide whether to start it.", nil
	case "task_update":
		t, err := s.currentTask(ctx, owner, in.Task, call.RoomID)
		if err != nil {
			return "", err
		}
		switch in.Status {
		case pm.StatusWorking, pm.StatusNeedsInput, pm.StatusReview:
		default:
			return "", errs.InvalidArgument("status is working, needs_input or ready_for_review")
		}
		t.Status, t.Summary = in.Status, clip(in.Summary, 500)
		if in.Status == pm.StatusReview {
			t.DoneAt = s.now().UTC()
		}
		if err := s.save(ctx, t); err != nil {
			return "", err
		}
		if in.Status != pm.StatusWorking {
			title := map[string]string{pm.StatusNeedsInput: "Needs your input: ", pm.StatusReview: "Ready for review: "}[in.Status]
			s.notify(ctx, t, title+t.Title, t.Summary)
		}
		return "Task " + t.ID.String() + " is now " + t.Status + ".", nil
	}
	return "", errs.NotFound("tool " + call.Tool)
}

// currentTask is the named task, or the person's task working in this room.
func (s *Service) currentTask(ctx context.Context, owner identity.ID, id, room string) (*pm.Task, error) {
	if id != "" {
		return s.task(ctx, owner, id)
	}
	var rows []pm.Task
	f := database.Filter{Equal: map[string]any{"owner_id": owner.String(), "status": pm.StatusWorking}, OrderBy: "updated_at", Limit: 20}
	if err := s.R.List(ctx, "tasks", f, &rows); err != nil {
		return nil, err
	}
	for i := range rows {
		if room == "" || rows[i].RoomID == room {
			return &rows[i], nil
		}
	}
	return nil, errs.NotFound("no task is being worked on here; pass task")
}

func (s *Service) duplicateSuggestion(ctx context.Context, owner identity.ID, title string) bool {
	var rows []pm.Task
	if err := s.R.List(ctx, "tasks", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "kind": pm.KindSuggestion}, OrderBy: "created_at", Limit: 50}, &rows); err != nil {
		return false
	}
	norm := strings.ToLower(strings.TrimSpace(title))
	for _, t := range rows {
		if strings.ToLower(strings.TrimSpace(t.Title)) == norm {
			return true
		}
	}
	return false
}

// suggestionCard is the card a suggestion shows in a room.
func suggestionCard(t *pm.Task) string {
	body, _ := agui.FormatMessage("", agui.SuggestionSurface(t.ID.String(), t.Title, t.Detail))
	return body
}
