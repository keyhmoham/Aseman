// Package responsibilities gives agents standing responsibilities: "when a
// customer emails about an order, draft the answer", "when a GitHub issue is
// labelled bug, triage it", "when someone asks in #support, answer". A
// responsibility belongs to a person and a room; when its trigger matches,
// the room's lead runs its instruction as that person, started as
// initiator "responsibility" (the audit trail's "nobody watching"), with
// the event handed over as outside content, and the outcome lands in their
// Tasks.
//
// Email triggers poll the owner's Gmail. GitHub, Slack and generic webhooks
// arrive at /hooks/v1/responsibilities/{id}, each verified by its own
// signature scheme with the responsibility's secret.
package responsibilities

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/pkg/untrusted"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Mail is a message as the google namespace returns it.
type Mail struct {
	ID      string    `json:"id"`
	From    string    `json:"from"`
	Subject string    `json:"subject"`
	Snippet string    `json:"snippet"`
	Date    time.Time `json:"date"`
	Labels  []string  `json:"labels,omitempty"`
}

// Ports this namespace uses.
type (
	SpacesPort interface {
		RunScheduledTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error)
	}
	GooglePort interface {
		Connected(ctx context.Context, accountID string) bool
		SearchMail(ctx context.Context, accountID, query string, max int) ([]Mail, error)
	}
	TasksPort interface {
		AddTask(ctx context.Context, t *pm.Task) (*pm.Task, error)
	}
)

// Service is the responsibilities namespace.
type Service struct {
	K      api.Kernel
	R      *repo.Repo
	L      *logger.Logger
	Spaces SpacesPort
	Google GooglePort
	Tasks  TasksPort
	now    func() time.Time
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("responsibilities"), now: time.Now}
}

func (s *Service) master() string { return s.K.Env()["node_private_key"] }

func sealContext(id string) string { return "responsibility/" + id }

// Input is what a person (or an agent for them) sets.
type Input struct {
	Space       string   `json:"space"`
	Room        string   `json:"room,omitempty"`
	Name        string   `json:"name"`
	Instruction string   `json:"instruction"`
	Trigger     string   `json:"trigger"`
	From        string   `json:"from,omitempty"`
	Subject     string   `json:"subject,omitempty"`
	Label       string   `json:"label,omitempty"`
	Repo        string   `json:"repo,omitempty"`
	Events      []string `json:"events,omitempty"`
	Action      string   `json:"action,omitempty"`
	Channel     string   `json:"channel,omitempty"`
	Keyword     string   `json:"keyword,omitempty"`
	// Secret is the provider's signing secret (Slack's); empty generates one.
	Secret string `json:"secret,omitempty"`
}

func (s *Service) canWrite(ctx context.Context, caller identity.ID, space string) bool {
	var rows []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": space, "member_id": caller.String()}}, &rows); err != nil {
		return false
	}
	for _, m := range rows {
		if m.Role == membership.RoleOwner || m.Role == membership.RoleAdmin || m.Role == membership.RoleMember {
			return true
		}
	}
	return false
}

// Create stores a responsibility. It returns the inbound URL and, when the
// node made the secret, the secret, once.
func (s *Service) Create(ctx context.Context, owner identity.ID, in Input) (*rm.Responsibility, map[string]string, error) {
	if !s.canWrite(ctx, owner, in.Space) {
		return nil, nil, errs.Permission("not a member of the project")
	}
	if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Instruction) == "" {
		return nil, nil, errs.InvalidArgument("a responsibility needs a name and an instruction")
	}
	switch in.Trigger {
	case rm.TriggerEmail:
		if in.From == "" && in.Subject == "" && in.Label == "" {
			return nil, nil, errs.InvalidArgument("an email trigger needs from, subject or label")
		}
	case rm.TriggerGitHub, rm.TriggerSlack, rm.TriggerWebhook:
	default:
		return nil, nil, errs.InvalidArgument("trigger is email, github, slack or webhook")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, nil, err
	}
	now := s.now().UTC()
	r := &rm.Responsibility{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner.String(), SpaceID: in.Space,
		RoomID: in.Room, Name: clip(in.Name, 120), Instruction: clip(in.Instruction, 4000), Trigger: in.Trigger, From: in.From,
		Subject: in.Subject, Label: in.Label, Repo: strings.ToLower(in.Repo), Events: in.Events, Action: in.Action,
		Channel: in.Channel, Keyword: in.Keyword, Enabled: true, Cursor: now}
	extra := map[string]string{}
	if in.Trigger != rm.TriggerEmail {
		secret := strings.TrimSpace(in.Secret)
		if secret == "" {
			b := make([]byte, 24)
			_, _ = rand.Read(b)
			secret = hex.EncodeToString(b)
			extra["secret"] = secret
		}
		sealed, err := crypto.SealSecret(secret, s.master(), sealContext(id.String()))
		if err != nil {
			return nil, nil, errs.Wrap(errs.CodeInternal, err, "seal secret")
		}
		r.Secret = sealed
		extra["url"] = HookPath + "/" + id.String()
	}
	if err := s.R.CreateID(ctx, "responsibilities", id, r); err != nil {
		return nil, nil, err
	}
	return r, extra, nil
}

// List is a person's responsibilities (in a project, or all).
func (s *Service) List(ctx context.Context, owner identity.ID, space string) ([]rm.Responsibility, error) {
	f := database.Filter{Equal: map[string]any{"owner_id": owner.String()}, OrderBy: "created_at", Limit: 200}
	if space != "" {
		f.Equal["space_id"] = space
	}
	var rows []rm.Responsibility
	return rows, s.R.List(ctx, "responsibilities", f, &rows)
}

func (s *Service) get(ctx context.Context, owner identity.ID, id string) (*rm.Responsibility, error) {
	rid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.InvalidArgument("invalid id")
	}
	var r rm.Responsibility
	if err := s.R.Get(ctx, "responsibilities", rid, &r); err != nil {
		return nil, err
	}
	if r.OwnerID != owner.String() {
		return nil, errs.NotFound("responsibility")
	}
	return &r, nil
}

// SetEnabled pauses or resumes a responsibility.
func (s *Service) SetEnabled(ctx context.Context, owner identity.ID, id string, on bool) (*rm.Responsibility, error) {
	r, err := s.get(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	r.Enabled, r.UpdatedAt = on, s.now().UTC()
	if on && r.Trigger == rm.TriggerEmail {
		r.Cursor = s.now().UTC()
	}
	return r, s.R.Update(ctx, "responsibilities", r.ID, r)
}

// Delete removes a responsibility.
func (s *Service) Delete(ctx context.Context, owner identity.ID, id string) error {
	r, err := s.get(ctx, owner, id)
	if err != nil {
		return err
	}
	return s.R.Delete(ctx, "responsibilities", r.ID)
}

// Fire runs a responsibility's instruction for one event, as its owner, with
// nobody watching.
func (s *Service) Fire(ctx context.Context, r *rm.Responsibility, source, event string) (string, error) {
	if !r.Enabled {
		return "", errs.Conflict("paused")
	}
	space, err := identity.Parse(r.SpaceID)
	if err != nil {
		return "", errs.InvalidArgument("invalid project")
	}
	room, _ := identity.Parse(r.RoomID)
	owner, err := identity.Parse(r.OwnerID)
	if err != nil {
		return "", errs.InvalidArgument("invalid owner")
	}
	task := fmt.Sprintf("⚡ Responsibility \"%s\": %s\n\nWhat happened:\n%s", r.Name, r.Instruction, untrusted.Wrap(source, clip(event, 6000)))
	runCtx := vmm.WithInitiator(ctx, vmm.Initiator{Kind: vmm.InitiatorResponsibility, ID: r.ID.String()})
	reply, runErr := s.Spaces.RunScheduledTask(runCtx, space, room, owner, task)
	r.Fired++
	r.LastFired = s.now().UTC()
	r.LastResult = clip(reply, 500)
	status := pm.StatusReview
	if runErr != nil {
		r.LastResult, status = "failed: "+runErr.Error(), pm.StatusFailed
	}
	r.UpdatedAt = s.now().UTC()
	_ = s.R.Update(context.WithoutCancel(ctx), "responsibilities", r.ID, r)
	if s.Tasks != nil {
		_, _ = s.Tasks.AddTask(context.WithoutCancel(ctx), &pm.Task{OwnerID: r.OwnerID, SpaceID: r.SpaceID, RoomID: r.RoomID, Kind: pm.KindWork,
			Status: status, Title: r.Name, Detail: clip(event, 300), Summary: clip(reply, 500), Source: "responsibility:" + r.ID.String(),
			Error: map[bool]string{true: "The run failed: " + errString(runErr)}[runErr != nil], Retryable: false, DoneAt: s.now().UTC()})
	}
	return reply, runErr
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// pollEmail fires email responsibilities for new matching mail.
func (s *Service) pollEmail(ctx context.Context) {
	if s.Google == nil {
		return
	}
	var rows []rm.Responsibility
	if err := s.R.List(ctx, "responsibilities", database.Filter{Equal: map[string]any{"trigger": rm.TriggerEmail, "enabled": true}, Limit: 200}, &rows); err != nil {
		return
	}
	for i := range rows {
		r := &rows[i]
		if !s.Google.Connected(ctx, r.OwnerID) {
			continue
		}
		mails, err := s.Google.SearchMail(ctx, r.OwnerID, EmailQuery(r), 10)
		if err != nil {
			continue
		}
		cursor := r.Cursor
		fired := 0
		for j := len(mails) - 1; j >= 0 && fired < 5; j-- {
			m := mails[j]
			if !m.Date.After(r.Cursor) {
				continue
			}
			event := fmt.Sprintf("Email id %s from %s on %s\nSubject: %s\n%s", m.ID, m.From, m.Date.Format(time.RFC1123), m.Subject, m.Snippet)
			_, _ = s.Fire(ctx, r, "email from "+m.From, event)
			fired++
			if m.Date.After(cursor) {
				cursor = m.Date
			}
		}
		if cursor.After(r.Cursor) {
			var cur rm.Responsibility
			if s.R.Get(ctx, "responsibilities", r.ID, &cur) == nil {
				cur.Cursor = cursor
				_ = s.R.Update(ctx, "responsibilities", r.ID, &cur)
			}
		}
	}
}

// EmailQuery is the Gmail search an email responsibility watches.
func EmailQuery(r *rm.Responsibility) string {
	parts := []string{"newer_than:2d"}
	quote := func(v string) string {
		if strings.ContainsAny(v, " \"") {
			return "\"" + strings.ReplaceAll(v, "\"", "") + "\""
		}
		return v
	}
	if r.From != "" {
		parts = append(parts, "from:"+quote(r.From))
	}
	if r.Subject != "" {
		parts = append(parts, "subject:"+quote(r.Subject))
	}
	if r.Label != "" {
		parts = append(parts, "label:"+quote(r.Label))
	}
	return strings.Join(parts, " ")
}

// Run polls email responsibilities.
func (s *Service) Run(ctx context.Context) {
	t := time.NewTicker(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.pollEmail(ctx)
		}
	}
}

// secret opens a responsibility's signing secret.
func (s *Service) secret(r *rm.Responsibility) (string, error) {
	return crypto.OpenSecret(r.Secret, s.master(), sealContext(r.ID.String()))
}

func hmacHex(secret string, parts ...[]byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	for _, p := range parts {
		mac.Write(p)
	}
	return hex.EncodeToString(mac.Sum(nil))
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ── bridges ─────────────────────────────────────────────────────────────────

type spacesBridge struct{ K api.Kernel }

func (b spacesBridge) RunScheduledTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error) {
	var out string
	err := bridge.Invoke(ctx, b.K, "spaces", "RunScheduledTask", []any{ctx, spaceID, roomID, actor, task}, &out)
	return out, err
}

type googleBridge struct{ K api.Kernel }

func (b googleBridge) Connected(ctx context.Context, accountID string) bool {
	var ok bool
	return bridge.Invoke(ctx, b.K, "google", "Connected", []any{ctx, accountID}, &ok) == nil && ok
}

func (b googleBridge) SearchMail(ctx context.Context, accountID, query string, max int) ([]Mail, error) {
	var out []Mail
	err := bridge.Invoke(ctx, b.K, "google", "SearchMail", []any{ctx, accountID, query, max}, &out)
	return out, err
}

type tasksBridge struct{ K api.Kernel }

func (b tasksBridge) AddTask(ctx context.Context, t *pm.Task) (*pm.Task, error) {
	var out *pm.Task
	err := bridge.Invoke(ctx, b.K, "proactive", "AddTask", []any{ctx, t}, &out)
	return out, err
}
