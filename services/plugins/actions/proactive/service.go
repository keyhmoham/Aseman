// Package proactive is the work Aseman does before it is asked: each
// person's Tasks (what needs them, what agents suggest, what agents work on),
// mail triage, the morning brief, background research and the first-day
// greeting.
//
// It is not a new orchestrator. Started tasks and greetings are ordinary
// turns of the project's lead (spaces.AskLead); background research is an
// ordinary run in a temporary thread (spaces.RunBackgroundTask) started as
// initiator "proactive", which the governance gate restricts to reads, so
// research can look but never act. Its only way to say what it found is the
// offer_task tool, which puts a suggestion in the person's Tasks.
package proactive

import (
	"context"
	"hash/fnv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// Mail is a message as the google namespace returns it.
type Mail struct {
	ID        string            `json:"id"`
	ThreadID  string            `json:"thread_id"`
	From      string            `json:"from"`
	To        string            `json:"to,omitempty"`
	Subject   string            `json:"subject"`
	Date      time.Time         `json:"date"`
	Snippet   string            `json:"snippet"`
	Labels    []string          `json:"labels,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	Body      string            `json:"body,omitempty"`
	MessageID string            `json:"message_id,omitempty"`
}

// Event is a calendar event as the google namespace returns it.
type Event struct {
	ID        string    `json:"id"`
	Summary   string    `json:"summary"`
	Start     time.Time `json:"start"`
	End       time.Time `json:"end"`
	AllDay    bool      `json:"all_day,omitempty"`
	Location  string    `json:"location,omitempty"`
	Attendees []string  `json:"attendees,omitempty"`
	Link      string    `json:"link,omitempty"`
}

// Completion and CompletionResult mirror the llm namespace's.
type Completion struct {
	Payer     identity.ID `json:"payer"`
	SpaceID   identity.ID `json:"space_id"`
	Purpose   string      `json:"purpose"`
	System    string      `json:"system"`
	User      string      `json:"user"`
	MaxTokens int         `json:"max_tokens,omitempty"`
	JSON      bool        `json:"json,omitempty"`
}

type CompletionResult struct {
	Text  string `json:"text"`
	Model string `json:"model"`
	Cost  int64  `json:"cost"`
}

// GooglePort is the person's mail and calendar.
type GooglePort interface {
	Connected(ctx context.Context, accountID string) bool
	SearchMail(ctx context.Context, accountID, query string, max int) ([]Mail, error)
	Events(ctx context.Context, accountID string, from, to time.Time, query string) ([]Event, error)
}

// SpacesPort runs the lead and reaches projects and rooms.
type SpacesPort interface {
	HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error)
	GetRoom(ctx context.Context, id identity.ID) (*space.Room, error)
	AskLead(ctx context.Context, actor, spaceID, roomID identity.ID, submission, body, prompt string, silent bool) (*turn.Turn, error)
	RunBackgroundTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error)
	PostMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error
	AsemanAccount(ctx context.Context) (identity.ID, error)
}

// LLMPort is the node's model, billed to the person.
type LLMPort interface {
	Complete(ctx context.Context, c Completion) (CompletionResult, error)
}

// PushNote mirrors the users namespace's notification.
type PushNote struct {
	Title    string `json:"title"`
	Body     string `json:"body"`
	Kind     string `json:"kind"`
	Space    string `json:"space,omitempty"`
	Room     string `json:"room,omitempty"`
	Collapse string `json:"collapse,omitempty"`
}

// UsersPort tells people on their devices.
type UsersPort interface {
	Push(ctx context.Context, to []identity.ID, note PushNote)
}

// Service is the proactive namespace.
type Service struct {
	K      api.Kernel
	R      *repo.Repo
	L      *logger.Logger
	Google GooglePort
	Spaces SpacesPort
	LLM    LLMPort
	Users  UsersPort
	now    func() time.Time
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("proactive"), now: time.Now}
}

// derivedID is a stable id for a (kind, key): the same brief, verdict or
// person record however many times it is asked for.
func (s *Service) derivedID(kind, key string) identity.ID {
	h := fnv.New64a()
	h.Write([]byte(kind + "\x00" + key))
	id, _ := identity.Parse(s.K.NodeID().String() + hex16(h.Sum64()))
	return id
}

func hex16(v uint64) string {
	const digits = "0123456789abcdef"
	b := make([]byte, 16)
	for i := 15; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b)
}

func (s *Service) isPerson(ctx context.Context, id string) bool {
	parsed, err := identity.Parse(id)
	if err != nil {
		return false
	}
	var acc account.Account
	return s.R.Get(ctx, "accounts", parsed, &acc) == nil && acc.Kind == account.KindUser && acc.Status == account.StatusActive
}

func (s *Service) displayName(ctx context.Context, id string) string {
	parsed, err := identity.Parse(id)
	if err != nil {
		return ""
	}
	var acc account.Account
	if s.R.Get(ctx, "accounts", parsed, &acc) != nil {
		return ""
	}
	return acc.Handle
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ── bridges ─────────────────────────────────────────────────────────────────

type googleBridge struct{ K api.Kernel }

func (b googleBridge) Connected(ctx context.Context, accountID string) bool {
	var ok bool
	if err := bridge.Invoke(ctx, b.K, "google", "Connected", []any{ctx, accountID}, &ok); err != nil {
		return false
	}
	return ok
}

func (b googleBridge) SearchMail(ctx context.Context, accountID, query string, max int) ([]Mail, error) {
	var out []Mail
	err := bridge.Invoke(ctx, b.K, "google", "SearchMail", []any{ctx, accountID, query, max}, &out)
	return out, err
}

func (b googleBridge) Events(ctx context.Context, accountID string, from, to time.Time, query string) ([]Event, error) {
	var out []Event
	err := bridge.Invoke(ctx, b.K, "google", "Events", []any{ctx, accountID, from, to, query}, &out)
	return out, err
}

type spacesBridge struct{ K api.Kernel }

func (b spacesBridge) HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error) {
	var out *space.Space
	err := bridge.Invoke(ctx, b.K, "spaces", "HomeSpace", []any{ctx, owner}, &out)
	return out, err
}

func (b spacesBridge) GetRoom(ctx context.Context, id identity.ID) (*space.Room, error) {
	var out *space.Room
	err := bridge.Invoke(ctx, b.K, "spaces", "GetRoom", []any{ctx, id}, &out)
	return out, err
}

func (b spacesBridge) AskLead(ctx context.Context, actor, spaceID, roomID identity.ID, submission, body, prompt string, silent bool) (*turn.Turn, error) {
	var out *turn.Turn
	err := bridge.Invoke(ctx, b.K, "spaces", "AskLead", []any{ctx, actor, spaceID, roomID, submission, body, prompt, silent}, &out)
	return out, err
}

func (b spacesBridge) RunBackgroundTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error) {
	var out string
	err := bridge.Invoke(ctx, b.K, "spaces", "RunBackgroundTask", []any{ctx, spaceID, roomID, actor, task}, &out)
	return out, err
}

func (b spacesBridge) PostMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error {
	return bridge.Invoke(ctx, b.K, "spaces", "PostMessage", []any{ctx, spaceID, roomID, sender, body})
}

func (b spacesBridge) AsemanAccount(ctx context.Context) (identity.ID, error) {
	var out identity.ID
	err := bridge.Invoke(ctx, b.K, "spaces", "AsemanAccount", []any{ctx}, &out)
	return out, err
}

type llmBridge struct{ K api.Kernel }

func (b llmBridge) Complete(ctx context.Context, c Completion) (CompletionResult, error) {
	var out CompletionResult
	err := bridge.Invoke(ctx, b.K, "llm", "Complete", []any{ctx, c}, &out)
	return out, err
}

type usersBridge struct{ K api.Kernel }

func (b usersBridge) Push(ctx context.Context, to []identity.ID, note PushNote) {
	_ = bridge.Invoke(ctx, b.K, "users", "Push", []any{ctx, to, note})
}
