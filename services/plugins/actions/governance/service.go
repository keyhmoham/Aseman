// Package governance decides, records and protects what agents do.
//
// Every action an agent takes, whichever door it comes through (the agent
// gateway, Code Mode, channels, host access), is one gate.Request decided here
// against the node's and the project's policies, written to the audit trail
// before it runs, and, when a rule asks, held until a person answers. The
// namespace also keeps the secret box and vault, the outbound credential
// checks, the project computers' egress policies and their handovers.
package governance

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SpacesPort is what governance needs from the spaces namespace: posting its
// cards into a room, the lead agent that posts them when no agent is named,
// and running commands on a project's computer (its egress policy).
type SpacesPort interface {
	PostMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error
	AsemanAccount(ctx context.Context) (identity.ID, error)
	SandboxExec(ctx context.Context, spaceID identity.ID, command string) (string, error)
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

// Service is the governance namespace.
type Service struct {
	K      api.Kernel
	R      *repo.Repo
	L      *logger.Logger
	Spaces SpacesPort
	Users  UsersPort

	now func() time.Time
	// ApprovalTimeout is how long an action waits on a person.
	ApprovalTimeout time.Duration
	// HandoverWait is how long an agent's computer action waits while a
	// person holds the computer.
	HandoverWait time.Duration
	// pollEvery is how often a waiting action rereads its record, for answers
	// given on another node.
	pollEvery time.Duration

	mu       sync.Mutex
	policies map[string]cachedPolicy
	waiters  map[string][]chan struct{}
}

type cachedPolicy struct {
	c       *compiled
	loaded  time.Time
	present bool
}

// policyTTL bounds how stale another node's policy edit can be here.
const policyTTL = 10 * time.Second

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	timeout := 30 * time.Minute
	if v, err := time.ParseDuration(strings.TrimSpace(os.Getenv("ASEMAN_APPROVAL_TIMEOUT"))); err == nil && v > 0 {
		timeout = v
	}
	return &Service{K: k, R: r, L: log.Named("governance"), now: time.Now, ApprovalTimeout: timeout, HandoverWait: timeout,
		pollEvery: 2 * time.Second, policies: map[string]cachedPolicy{}, waiters: map[string][]chan struct{}{}}
}

func (s *Service) newID() (identity.ID, error) { return identity.New(s.K.NodeID()) }

// isAdmin reports a node administrator.
func (s *Service) isAdmin(ctx context.Context, caller identity.ID) bool {
	var acc account.Account
	if caller.IsZero() || s.R.Get(ctx, "accounts", caller, &acc) != nil {
		return false
	}
	if acc.Kind != account.KindUser || acc.Status != account.StatusActive {
		return false
	}
	return acc.Role == "admin" || (acc.Handle != "" && acc.Handle == s.K.Env()["admin_handle"])
}

// canManage reports a project's owner or administrator (or a node admin).
func (s *Service) canManage(ctx context.Context, caller identity.ID, space string) bool {
	if s.isAdmin(ctx, caller) {
		return true
	}
	if caller.IsZero() || space == "" {
		return false
	}
	var rows []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": space, "member_id": caller.String()}}, &rows); err != nil {
		return false
	}
	for i := range rows {
		if rows[i].RoomID.IsZero() && rows[i].CanManage() {
			return true
		}
	}
	return false
}

// isMember reports any membership of the caller in the project.
func (s *Service) isMember(ctx context.Context, caller identity.ID, space string) bool {
	if caller.IsZero() || space == "" {
		return false
	}
	n, err := s.R.Count(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": space, "member_id": caller.String()}})
	return err == nil && n > 0
}

// isPerson reports an account that is a person (not an agent or app).
func (s *Service) isPerson(ctx context.Context, id string) bool {
	parsed, err := identity.Parse(id)
	if err != nil {
		return false
	}
	var acc account.Account
	if s.R.Get(ctx, "accounts", parsed, &acc) != nil {
		return false
	}
	return acc.Kind == account.KindUser
}

type spacesBridge struct{ K api.Kernel }

func (b spacesBridge) PostMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error {
	return bridge.Invoke(ctx, b.K, "spaces", "PostMessage", []any{ctx, spaceID, roomID, sender, body})
}

func (b spacesBridge) AsemanAccount(ctx context.Context) (identity.ID, error) {
	var out identity.ID
	err := bridge.Invoke(ctx, b.K, "spaces", "AsemanAccount", []any{ctx}, &out)
	return out, err
}

func (b spacesBridge) SandboxExec(ctx context.Context, spaceID identity.ID, command string) (string, error) {
	var out string
	err := bridge.Invoke(ctx, b.K, "spaces", "SandboxExec", []any{ctx, spaceID, command}, &out)
	return out, err
}

type usersBridge struct{ K api.Kernel }

func (b usersBridge) Push(ctx context.Context, to []identity.ID, note PushNote) {
	_ = bridge.Invoke(ctx, b.K, "users", "Push", []any{ctx, to, note})
}

var errNotAllowed = errs.Permission("project owner or administrator required")
