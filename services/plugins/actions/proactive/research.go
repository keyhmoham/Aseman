package proactive

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Background research: every few hours the person's lead looks through what
// is new in their connected apps, read-only, and suggests next steps. A run
// is a check-in: it reads only what is new since the last one, and most end
// with nothing recorded and nothing said. When one finds something, the lead
// writes first, in the person's home conversation, with each suggestion as a
// card to Start or Hide.

// researchDefault is whether research is on for a person who has not chosen.
func researchDefault() bool { return os.Getenv("ASEMAN_PROACTIVE_DEFAULTS") != "false" }

// Run is the namespace's worker: it follows started tasks and runs the
// research that is due.
func (s *Service) Run(ctx context.Context) {
	follow := time.NewTicker(5 * time.Second)
	research := time.NewTicker(2 * time.Minute)
	defer follow.Stop()
	defer research.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-follow.C:
			s.follow(ctx)
		case <-research.C:
			s.researchDue(ctx)
		}
	}
}

func (s *Service) researchDue(ctx context.Context) {
	due, err := s.dueForResearch(ctx)
	if err != nil {
		return
	}
	for i := range due {
		p := due[i]
		// Claim it first, so another node (or the next tick) does not.
		p.NextResearchAt = s.now().UTC().Add(time.Duration(max(p.IntervalHours, 1)) * time.Hour)
		if changed, err := s.claim(ctx, &p, due[i].NextResearchAt); err != nil || !changed {
			continue
		}
		result, err := s.Research(ctx, p.ID)
		p.LastResearchAt, p.LastResult = s.now().UTC(), result
		if err != nil {
			p.LastResult = "failed: " + err.Error()
		}
		_ = s.R.Update(context.WithoutCancel(ctx), "proactive_people", p.ID, &p)
	}
}

func (s *Service) claim(ctx context.Context, p *pm.Person, was time.Time) (bool, error) {
	if err := s.R.RequireAtomicUpdates(); err != nil {
		return true, s.R.Update(ctx, "proactive_people", p.ID, p)
	}
	return s.R.CompareAndSwap(ctx, "proactive_people", p.ID.String(), map[string]any{"next_research_at": was}, p)
}

// Research runs one check-in for a person now.
func (s *Service) Research(ctx context.Context, owner identity.ID) (string, error) {
	if s.Google == nil || !s.Google.Connected(ctx, owner.String()) {
		return "skipped: nothing connected to look at", nil
	}
	home := s.homeSpaceID(ctx, owner)
	if home.IsZero() {
		return "", errs.NotFound("no home project")
	}
	var p pm.Person
	_ = s.R.Get(ctx, "proactive_people", owner, &p)
	since := p.LastResearchAt
	if since.IsZero() {
		since = s.now().Add(-48 * time.Hour)
	}
	started := s.now().UTC()
	hours := int(time.Since(since).Hours()) + 1
	prompt := fmt.Sprintf(`Background check-in for the person (nobody is watching; you can only read).
Look at what is new since %s: their mail (gmail_search "in:inbox newer_than:%dh"), their calendar for the next two days (calendar_events), and anything a message refers to.
If something likely needs doing — a reply owed, a deadline, a meeting to prepare for, a follow-up — suggest it with offer_task: a short imperative title, what you found, and why it matters now. At most three suggestions, none already suggested.
Do not send, draft, schedule or change anything, and do not message anyone: those are refused in a check-in. If nothing is worth suggesting, answer exactly "nothing new".`,
		since.Format(time.RFC1123), hours)
	runCtx := vmm.WithInitiator(ctx, vmm.Initiator{Kind: vmm.InitiatorProactive, ID: owner.String()})
	reply, err := s.Spaces.RunBackgroundTask(runCtx, home, identity.ID{}, owner, prompt)
	if err != nil {
		return "", err
	}
	var fresh []pm.Task
	_ = s.R.List(ctx, "tasks", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "kind": pm.KindSuggestion},
		GreaterThan: map[string]any{"created_at": started}, OrderBy: "created_at", Asc: true, Limit: 10}, &fresh)
	if len(fresh) == 0 {
		return clip("nothing new: "+reply, 300), nil
	}
	lead, err := s.Spaces.AsemanAccount(ctx)
	if err == nil {
		intro := fmt.Sprintf("While you were away I looked through what's new and found %d thing%s you may want to start.", len(fresh), plural(len(fresh)))
		_ = s.Spaces.PostMessage(ctx, home, identity.ID{}, lead, intro)
		for i := range fresh {
			fresh[i].SpaceID = home.String()
			_ = s.Spaces.PostMessage(ctx, home, identity.ID{}, lead, suggestionCard(&fresh[i]))
		}
	}
	return fmt.Sprintf("%d suggestions", len(fresh)), nil
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// SetResearch turns a person's background research on or off and sets how
// often it runs.
func (s *Service) SetResearch(ctx context.Context, owner identity.ID, on bool, hours int64, briefOff *bool) (*pm.Person, error) {
	p := s.person(ctx, owner, "")
	p.Research, p.ResearchOptOut = on, !on
	if hours > 0 {
		if hours > 48 {
			hours = 48
		}
		p.IntervalHours = hours
	}
	if briefOff != nil {
		p.BriefOff = *briefOff
	}
	if on && p.NextResearchAt.IsZero() {
		p.NextResearchAt = s.now().UTC().Add(time.Duration(p.IntervalHours) * time.Hour)
	}
	p.UpdatedAt = s.now().UTC()
	return p, s.R.Update(ctx, "proactive_people", owner, p)
}

// ── the first day ───────────────────────────────────────────────────────────

// FirstDay greets a person the first time they open their home project: the
// lead speaks first, reads their recent mail and this week's calendar when
// they are connected, and answers in three short messages, ending with
// "Sounds right" / "Something's off" to tap. Without Google it promises no
// mail: it says what it can do now. It runs once.
func (s *Service) FirstDay(ctx context.Context, owner identity.ID, tz string) (map[string]any, error) {
	p := s.person(ctx, owner, tz)
	connected := s.Google != nil && s.Google.Connected(ctx, owner.String())
	if !p.FirstDayAt.IsZero() {
		return map[string]any{"started": false, "google_connected": connected}, nil
	}
	was := p.FirstDayAt
	p.FirstDayAt = s.now().UTC()
	if s.R.RequireAtomicUpdates() == nil {
		if ok, err := s.R.CompareAndSwap(ctx, "proactive_people", owner.String(), map[string]any{"first_day_at": was}, p); err != nil || !ok {
			return map[string]any{"started": false, "google_connected": connected}, err
		}
	} else if err := s.R.Update(ctx, "proactive_people", owner, p); err != nil {
		return nil, err
	}
	home := s.homeSpaceID(ctx, owner)
	if home.IsZero() {
		return nil, errs.NotFound("no home project")
	}
	var prompt string
	if connected {
		prompt = `This is the person's first day with you. Speak first. Read their recent mail (gmail_search "newer_than:14d", then gmail_read the few that tell you most) and this week's calendar (calendar_events for the next 7 days).
Then answer in exactly three short messages, separated by a line with only "---":
1. Who you think they are and what their work looks like, from what you read (two or three sentences, concrete).
2. Three specific ways you can help this week, from what you saw.
3. An invitation to correct you.
End the third message with <replies>Sounds right | Something's off</replies>. Do not send or change anything.`
	} else {
		prompt = `This is the person's first day with you. Speak first. Their mail and calendar are not connected, so promise nothing about them.
Answer in exactly three short messages, separated by a line with only "---":
1. A warm one-line hello and what you are: an assistant that works on its own computer, keeps going while they are away, and asks before it sends, pays, signs or deletes anything.
2. Three things you can do right now without their mail (research something, build a small tool, draft a document), and that connecting Gmail and Calendar lets you start their day with a brief.
3. A question about what they work on.
End the third message with <replies>Connect my mail | Tell me more | Not now</replies>.`
	}
	if _, err := s.Spaces.AskLead(ctx, owner, home, identity.ID{}, "first-day-"+owner.String(), "", prompt, true); err != nil {
		return nil, err
	}
	return map[string]any{"started": true, "google_connected": connected, "space": home.String()}, nil
}
