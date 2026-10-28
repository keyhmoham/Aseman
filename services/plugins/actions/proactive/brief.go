package proactive

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	"github.com/aseman/aseman/plugins/actions/proactive/triage"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// ── triage ──────────────────────────────────────────────────────────────────

// Triage sorts the person's recent inbox, reusing earlier verdicts: a
// message is decided once.
func (s *Service) Triage(ctx context.Context, owner identity.ID, query string, max int) ([]pm.MailVerdict, []string, error) {
	if s.Google == nil || !s.Google.Connected(ctx, owner.String()) {
		return nil, nil, errs.New(errs.CodeUnavailable, "Google is not connected")
	}
	if query == "" {
		query = "in:inbox newer_than:2d"
	}
	mails, err := s.Google.SearchMail(ctx, owner.String(), query, max)
	if err != nil {
		return nil, nil, err
	}
	var out []pm.MailVerdict
	var todo []triage.Mail
	byID := map[string]Mail{}
	for _, m := range mails {
		byID[m.ID] = m
		var known pm.MailVerdict
		if s.R.Get(ctx, "mail_verdicts", s.derivedID("verdict", owner.String()+"/"+m.ID), &known) == nil {
			out = append(out, known)
			continue
		}
		todo = append(todo, triage.Mail{ID: m.ID, From: m.From, To: m.To, Subject: m.Subject, Snippet: m.Snippet, Date: m.Date,
			Labels: m.Labels, Headers: m.Headers})
	}
	space := s.homeSpaceID(ctx, owner)
	model := func(system, user string) (string, string, error) {
		if s.LLM == nil {
			return "", "", errs.New(errs.CodeUnavailable, "no model")
		}
		res, err := s.LLM.Complete(ctx, Completion{Payer: owner, SpaceID: space, Purpose: "mail triage", System: system, User: user, MaxTokens: 1500, JSON: true})
		return res.Text, res.Model, err
	}
	verdicts, undecided := triage.Sort(s.displayName(ctx, owner.String()), todo, model, 20)
	now := s.now().UTC()
	for _, v := range verdicts {
		m := byID[v.ID]
		row := pm.MailVerdict{Entity: entity.Entity{ID: s.derivedID("verdict", owner.String()+"/"+v.ID), CreatedAt: now, UpdatedAt: now},
			OwnerID: owner.String(), MailID: v.ID, Verdict: v.Verdict, Reason: v.Reason, DecidedBy: v.DecidedBy,
			From: m.From, Subject: m.Subject, Date: m.Date}
		if err := s.R.CreateID(ctx, "mail_verdicts", row.ID, &row); err != nil && errs.CodeOf(err) != errs.CodeAlreadyExists {
			s.L.Warn("verdict not kept", "error", err)
		}
		out = append(out, row)
	}
	return out, undecided, nil
}

func (s *Service) homeSpaceID(ctx context.Context, owner identity.ID) identity.ID {
	if s.Spaces == nil {
		return identity.ID{}
	}
	if home, err := s.Spaces.HomeSpace(ctx, owner); err == nil && home != nil {
		return home.ID
	}
	return identity.ID{}
}

// ── the morning brief ───────────────────────────────────────────────────────

// BriefItem is one row of a brief.
type BriefItem struct {
	MailID  string `json:"mail_id,omitempty"`
	TaskID  string `json:"task_id,omitempty"`
	From    string `json:"from,omitempty"`
	Subject string `json:"subject"`
	Reason  string `json:"reason,omitempty"`
}

// BriefContent is what a brief says.
type BriefContent struct {
	Day       string      `json:"day"`
	NeedsYou  []BriefItem `json:"needs_you"`
	CanWait   []BriefItem `json:"can_wait"`
	Calendar  []Event     `json:"calendar"`
	Tasks     []BriefItem `json:"tasks"`
	Unchecked []string    `json:"unchecked"`
}

// today is the person's date in their timezone.
func (s *Service) today(tz string) (string, *time.Location) {
	loc, err := time.LoadLocation(strings.TrimSpace(tz))
	if err != nil || strings.TrimSpace(tz) == "" {
		loc = time.UTC
	}
	return s.now().In(loc).Format("2006-01-02"), loc
}

// BriefToday is the person's brief for today: made and posted once, the
// first time they open Chat on a day after their first (however many tabs or
// devices ask), and returned as it is after that. force rebuilds it on
// request. ok is false when there is no brief today (their first day, or the
// brief is off).
func (s *Service) BriefToday(ctx context.Context, owner identity.ID, tz string, force bool) (*pm.Brief, bool, error) {
	person := s.person(ctx, owner, tz)
	day, loc := s.today(person.Timezone)
	id := s.derivedID("brief", owner.String()+"/"+day)
	var existing pm.Brief
	if s.R.Get(ctx, "briefs", id, &existing) == nil && !force {
		return &existing, true, nil
	}
	if !force {
		if person.BriefOff {
			return nil, false, nil
		}
		// The first day is the greeting's; the brief starts the day after.
		if person.FirstSeen.In(loc).Format("2006-01-02") == day {
			return nil, false, nil
		}
	}
	content := s.buildBrief(ctx, owner, day, loc)
	raw, _ := json.Marshal(content)
	var asMap map[string]any
	_ = json.Unmarshal(raw, &asMap)
	home := s.homeSpaceID(ctx, owner)
	now := s.now().UTC()
	b := &pm.Brief{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner.String(), Day: day,
		SpaceID: home.String(), Content: asMap}
	if force && existing.ID == id {
		b.CreatedAt = existing.CreatedAt
		if err := s.R.Update(ctx, "briefs", id, b); err != nil {
			return nil, false, err
		}
	} else if err := s.R.CreateID(ctx, "briefs", id, b); err != nil {
		// Another tab made it first: that one stands.
		if errs.CodeOf(err) == errs.CodeAlreadyExists && s.R.Get(ctx, "briefs", id, &existing) == nil {
			return &existing, true, nil
		}
		return nil, false, err
	}
	if !home.IsZero() && s.Spaces != nil {
		if lead, err := s.Spaces.AsemanAccount(ctx); err == nil {
			if err := s.Spaces.PostMessage(ctx, home, identity.ID{}, lead, briefMarkdown(content)); err == nil {
				b.Posted = true
				_ = s.R.Update(ctx, "briefs", id, b)
			}
		}
	}
	// Slack, Teams or SMS, where the person linked them for notices.
	if s.K != nil {
		_ = bridge.Invoke(ctx, s.K, "channels", "Notify", []any{ctx, owner.String(), briefMarkdown(content)})
	}
	if s.Users != nil {
		s.Users.Push(ctx, []identity.ID{owner}, PushNote{Title: "Your brief for today",
			Body: fmt.Sprintf("%d need you · %d events today", len(content.NeedsYou), len(content.Calendar)), Kind: "brief",
			Space: home.String(), Collapse: "brief-" + day})
	}
	return b, true, nil
}

// buildBrief gathers the day: triaged mail, today's calendar, tasks waiting
// on the person, and what could not be checked.
func (s *Service) buildBrief(ctx context.Context, owner identity.ID, day string, loc *time.Location) BriefContent {
	c := BriefContent{Day: day, NeedsYou: []BriefItem{}, CanWait: []BriefItem{}, Calendar: []Event{}, Tasks: []BriefItem{}, Unchecked: []string{}}
	if s.Google != nil && s.Google.Connected(ctx, owner.String()) {
		verdicts, undecided, err := s.Triage(ctx, owner, "in:inbox newer_than:1d", 40)
		if err != nil {
			c.Unchecked = append(c.Unchecked, "Mail: "+err.Error())
		}
		for _, v := range verdicts {
			item := BriefItem{MailID: v.MailID, From: v.From, Subject: v.Subject, Reason: v.Reason}
			if v.Verdict == triage.NeedsYou {
				c.NeedsYou = append(c.NeedsYou, item)
			} else {
				c.CanWait = append(c.CanWait, item)
			}
		}
		if len(undecided) > 0 {
			c.Unchecked = append(c.Unchecked, fmt.Sprintf("%d messages could not be sorted", len(undecided)))
		}
		start, _ := time.ParseInLocation("2006-01-02", day, loc)
		events, err := s.Google.Events(ctx, owner.String(), start, start.Add(24*time.Hour), "")
		if err != nil {
			c.Unchecked = append(c.Unchecked, "Calendar: "+err.Error())
		} else {
			c.Calendar = events
		}
	} else {
		c.Unchecked = append(c.Unchecked, "Mail and calendar: Google is not connected")
	}
	if tasks, err := s.Tasks(ctx, owner, "", false); err == nil {
		for _, t := range tasks {
			if t.Status == pm.StatusNeedsInput || t.Status == pm.StatusReview || t.Status == pm.StatusFailed {
				c.Tasks = append(c.Tasks, BriefItem{TaskID: t.ID.String(), Subject: t.Title, Reason: statusLine(t.Status)})
			}
		}
	}
	return c
}

func statusLine(status string) string {
	return map[string]string{pm.StatusNeedsInput: "needs your input", pm.StatusReview: "ready for review", pm.StatusFailed: "could not finish"}[status]
}

// briefMarkdown is the brief as the chat shows it.
func briefMarkdown(c BriefContent) string {
	var b strings.Builder
	fmt.Fprintf(&b, "**Good morning — your brief for %s**\n\n", c.Day)
	if len(c.NeedsYou) > 0 {
		b.WriteString("**Needs you**\n")
		for _, i := range c.NeedsYou {
			fmt.Fprintf(&b, "- %s — %s\n", i.Subject, i.Reason)
		}
		b.WriteString("\n")
	} else {
		b.WriteString("Nothing in your mail needs you right now.\n\n")
	}
	if len(c.Calendar) > 0 {
		b.WriteString("**Today**\n")
		for _, e := range c.Calendar {
			when := e.Start.Format("15:04")
			if e.AllDay {
				when = "All day"
			}
			fmt.Fprintf(&b, "- %s · %s\n", when, e.Summary)
		}
		b.WriteString("\n")
	}
	if len(c.Tasks) > 0 {
		b.WriteString("**Tasks waiting on you**\n")
		for _, t := range c.Tasks {
			fmt.Fprintf(&b, "- %s (%s)\n", t.Subject, t.Reason)
		}
		b.WriteString("\n")
	}
	if len(c.CanWait) > 0 {
		fmt.Fprintf(&b, "%d more can wait.\n", len(c.CanWait))
	}
	for _, u := range c.Unchecked {
		b.WriteString("_Not checked: " + u + "_\n")
	}
	return strings.TrimSpace(b.String())
}

// StartFromMail hands an email that needs the person to the lead as a task.
func (s *Service) StartFromMail(ctx context.Context, owner identity.ID, mailID string) (*pm.Task, error) {
	var v pm.MailVerdict
	if err := s.R.Get(ctx, "mail_verdicts", s.derivedID("verdict", owner.String()+"/"+mailID), &v); err != nil {
		return nil, errs.NotFound("that email is not in your brief")
	}
	home := s.homeSpaceID(ctx, owner)
	t, err := s.AddTask(ctx, &pm.Task{OwnerID: owner.String(), SpaceID: home.String(), Kind: pm.KindNeedsYou, Status: pm.StatusSuggested,
		Title: "Handle: " + v.Subject, Detail: "From " + v.From, Reason: v.Reason, Source: "mail:" + mailID})
	if err != nil {
		return nil, err
	}
	return s.Start(ctx, owner, t.ID.String())
}

// person is the person's proactive record, created on first use.
func (s *Service) person(ctx context.Context, owner identity.ID, tz string) *pm.Person {
	var p pm.Person
	if err := s.R.Get(ctx, "proactive_people", owner, &p); err == nil {
		if tz != "" && tz != p.Timezone {
			if _, err := time.LoadLocation(tz); err == nil {
				p.Timezone, p.UpdatedAt = tz, s.now().UTC()
				_ = s.R.Update(ctx, "proactive_people", owner, &p)
			}
		}
		return &p
	}
	now := s.now().UTC()
	p = pm.Person{Entity: entity.Entity{ID: owner, CreatedAt: now, UpdatedAt: now}, Research: researchDefault(), IntervalHours: 4,
		FirstSeen: now, NextResearchAt: now.Add(4 * time.Hour)}
	if _, err := time.LoadLocation(tz); err == nil {
		p.Timezone = tz
	}
	if err := s.R.CreateID(ctx, "proactive_people", owner, &p); err != nil && errs.CodeOf(err) == errs.CodeAlreadyExists {
		_ = s.R.Get(ctx, "proactive_people", owner, &p)
	}
	return &p
}

// People lists the records due for background research.
func (s *Service) dueForResearch(ctx context.Context) ([]pm.Person, error) {
	var rows []pm.Person
	err := s.R.List(ctx, "proactive_people", database.Filter{Equal: map[string]any{"research": true},
		LessThan: map[string]any{"next_research_at": s.now().UTC()}, Limit: 50}, &rows)
	return rows, err
}
