// Package channels lets people reach their agents where they already are:
// Slack, Microsoft Teams and text messages. A person links each identity to
// their account with a one-time code; from then on a message from it runs as
// a turn of their lead, in their home project (or a room they chose), as
// them, and the answer is sent back where they wrote. Approvals the person is
// asked for are offered there too (buttons in Slack, an Adaptive Card in
// Teams, a code by SMS), and answering there answers it in Aseman.
//
// Nothing in a message chooses whom a turn runs as: the provider's signed
// delivery names the sender, and the binding decides the account.
package channels

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Ports this namespace uses.
type (
	SpacesPort interface {
		HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error)
		RunScheduledTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error)
	}
	GovernancePort interface {
		Answer(ctx context.Context, caller identity.ID, approvalID, answer string) error
	}
)

// Service is the channels namespace.
type Service struct {
	K          api.Kernel
	R          *repo.Repo
	L          *logger.Logger
	Spaces     SpacesPort
	Governance GovernancePort
	HTTP       *http.Client
	now        func() time.Time
	// Endpoints of the providers, replaced in tests.
	SlackAPI, TwilioAPI, BotFrameworkToken, BotFrameworkOpenID string
	// run starts a channel turn; tests run it inline.
	run  func(func())
	jwks *keyCache
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("channels"), HTTP: &http.Client{Timeout: 30 * time.Second}, now: time.Now,
		SlackAPI: "https://slack.com/api", TwilioAPI: "https://api.twilio.com/2010-04-01",
		BotFrameworkToken:  "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token",
		BotFrameworkOpenID: "https://login.botframework.com/v1/.well-known/openidconfiguration",
		run:                func(f func()) { go f() }, jwks: &keyCache{}}
}

func (s *Service) master() string { return s.K.Env()["node_private_key"] }

func settingsID(k api.Kernel, provider string) identity.ID {
	h := sha256.Sum256([]byte("channels/" + provider))
	id, _ := identity.Parse(k.NodeID().String() + hex.EncodeToString(h[:8]))
	return id
}

// settings is a provider's configuration with its secrets opened.
type opened struct {
	cm.Settings
	secret, token string
}

func (s *Service) settings(ctx context.Context, provider string) (*opened, error) {
	var st cm.Settings
	if err := s.R.Get(ctx, "channel_settings", settingsID(s.K, provider), &st); err != nil {
		return nil, errs.New(errs.CodeUnavailable, provider+" is not set up on this node")
	}
	o := &opened{Settings: st}
	var err error
	if st.Secret != "" {
		if o.secret, err = crypto.OpenSecret(st.Secret, s.master(), "channels/"+provider+"/secret"); err != nil {
			return nil, errs.Wrap(errs.CodeInternal, err, "open channel secret")
		}
	}
	if st.Token != "" {
		if o.token, err = crypto.OpenSecret(st.Token, s.master(), "channels/"+provider+"/token"); err != nil {
			return nil, errs.Wrap(errs.CodeInternal, err, "open channel token")
		}
	}
	return o, nil
}

// SaveSettings stores a provider's configuration; empty secrets keep the old.
func (s *Service) SaveSettings(ctx context.Context, by identity.ID, in cm.Settings, secret, token string) (*cm.Settings, error) {
	switch in.Provider {
	case cm.Slack, cm.Teams, cm.Twilio:
	default:
		return nil, errs.InvalidArgument("provider is slack, teams or twilio")
	}
	id := settingsID(s.K, in.Provider)
	now := s.now().UTC()
	var st cm.Settings
	exists := s.R.Get(ctx, "channel_settings", id, &st) == nil
	if !exists {
		st = cm.Settings{Entity: entity.Entity{ID: id, CreatedAt: now}, Provider: in.Provider}
	}
	st.Enabled, st.AppID, st.From, st.Tenant, st.UpdatedBy, st.UpdatedAt = in.Enabled, strings.TrimSpace(in.AppID), strings.TrimSpace(in.From),
		strings.TrimSpace(in.Tenant), by.String(), now
	for _, kv := range []struct {
		value, field, ctx string
	}{{secret, "secret", "channels/" + in.Provider + "/secret"}, {token, "token", "channels/" + in.Provider + "/token"}} {
		if kv.value == "" {
			continue
		}
		sealed, err := crypto.SealSecret(kv.value, s.master(), kv.ctx)
		if err != nil {
			return nil, errs.Wrap(errs.CodeInternal, err, "seal")
		}
		if kv.field == "secret" {
			st.Secret = sealed
		} else {
			st.Token = sealed
		}
	}
	var err error
	if exists {
		err = s.R.Update(ctx, "channel_settings", id, &st)
	} else {
		err = s.R.CreateID(ctx, "channel_settings", id, &st)
	}
	return &st, err
}

// ── linking ─────────────────────────────────────────────────────────────────

const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func hashCode(code string) string {
	h := sha256.Sum256([]byte(strings.ToUpper(strings.TrimSpace(code))))
	return hex.EncodeToString(h[:])
}

// LinkCode makes a one-time code the person sends from the provider.
func (s *Service) LinkCode(ctx context.Context, accountID identity.ID, provider string) (string, error) {
	st, err := s.settings(ctx, provider)
	if err != nil {
		return "", err
	}
	if !st.Enabled {
		return "", errs.New(errs.CodeUnavailable, provider+" is turned off")
	}
	code := make([]byte, 6)
	for i := range code {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			return "", err
		}
		code[i] = codeAlphabet[n.Int64()]
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	lc := &cm.LinkCode{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AccountID: accountID.String(), Provider: provider,
		CodeHash: hashCode(string(code)), ExpiresAt: now.Add(10 * time.Minute)}
	if err := s.R.CreateID(ctx, "channel_link_codes", id, lc); err != nil {
		return "", err
	}
	return string(code), nil
}

// redeem binds an identity with a code sent from it. It answers what to tell
// the sender.
func (s *Service) redeem(ctx context.Context, provider, code string, b cm.Binding) string {
	var rows []cm.LinkCode
	if err := s.R.List(ctx, "channel_link_codes", database.Filter{Equal: map[string]any{"code_hash": hashCode(code), "provider": provider}, Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return "That code is not valid. Get a new one in Aseman under Settings → Channels."
	}
	lc := rows[0]
	_ = s.R.Delete(ctx, "channel_link_codes", lc.ID)
	if !s.now().Before(lc.ExpiresAt) {
		return "That code expired. Get a new one in Aseman under Settings → Channels."
	}
	if existing, ok := s.binding(ctx, provider, b.Workspace, b.External); ok {
		_ = s.R.Delete(ctx, "channel_bindings", existing.ID)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "Linking failed; try again."
	}
	now := s.now().UTC()
	b.Entity, b.AccountID, b.Provider, b.Notify = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, lc.AccountID, provider, true
	if err := s.R.CreateID(ctx, "channel_bindings", id, &b); err != nil {
		return "Linking failed; try again."
	}
	return "Linked. Write to me here and I'll work on it in Aseman, as you. I ask before I send, pay, sign or delete anything."
}

func (s *Service) binding(ctx context.Context, provider, workspace, external string) (*cm.Binding, bool) {
	eq := map[string]any{"provider": provider, "external": external}
	if workspace != "" {
		eq["workspace"] = workspace
	}
	var rows []cm.Binding
	if err := s.R.List(ctx, "channel_bindings", database.Filter{Equal: eq, Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return nil, false
	}
	return &rows[0], true
}

// Bindings lists a person's linked identities.
func (s *Service) Bindings(ctx context.Context, accountID identity.ID) ([]cm.Binding, error) {
	var rows []cm.Binding
	return rows, s.R.List(ctx, "channel_bindings", database.Filter{Equal: map[string]any{"account_id": accountID.String()}, Limit: 50}, &rows)
}

// Unlink removes one of a person's bindings.
func (s *Service) Unlink(ctx context.Context, accountID, id identity.ID) error {
	var b cm.Binding
	if err := s.R.Get(ctx, "channel_bindings", id, &b); err != nil {
		return err
	}
	if b.AccountID != accountID.String() {
		return errs.NotFound("binding")
	}
	return s.R.Delete(ctx, "channel_bindings", id)
}

// RevokeBindings removes every binding of an account (deprovisioned).
func (s *Service) RevokeBindings(ctx context.Context, accountID identity.ID) error {
	rows, err := s.Bindings(ctx, accountID)
	if err != nil {
		return err
	}
	for _, b := range rows {
		_ = s.R.Delete(ctx, "channel_bindings", b.ID)
	}
	return nil
}

// linkCommand reads "link ABC123".
func linkCommand(text string) (string, bool) {
	f := strings.Fields(strings.TrimSpace(text))
	if len(f) == 2 && strings.EqualFold(f[0], "link") && len(f[1]) == 6 {
		return strings.ToUpper(f[1]), true
	}
	return "", false
}

// ── turns ───────────────────────────────────────────────────────────────────

// converse runs the person's message as a turn of their lead and hands the
// answer to reply. It returns at once; the turn runs after.
func (s *Service) converse(ctx context.Context, b *cm.Binding, text string, reply func(context.Context, string)) {
	if !s.isActive(ctx, b.AccountID) {
		return
	}
	s.run(func() {
		bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Minute)
		defer cancel()
		actor, _ := identity.Parse(b.AccountID)
		space, err := identity.Parse(b.SpaceID)
		if err != nil {
			home, herr := s.Spaces.HomeSpace(bg, actor)
			if herr != nil {
				reply(bg, "I couldn't find your home project in Aseman.")
				return
			}
			space = home.ID
		}
		room, _ := identity.Parse(b.RoomID)
		bg = vmm.WithInitiator(bg, vmm.Initiator{Kind: vmm.InitiatorChannel, ID: b.Provider + ":" + b.External})
		answer, err := s.Spaces.RunScheduledTask(bg, space, room, actor, text)
		if err != nil {
			answer = "I couldn't finish that: " + err.Error()
		}
		if strings.TrimSpace(answer) == "" {
			answer = "Done."
		}
		reply(bg, answer)
	})
}

func (s *Service) isActive(ctx context.Context, accountID string) bool {
	id, err := identity.Parse(accountID)
	if err != nil {
		return false
	}
	var acc account.Account
	return s.R.Get(ctx, "accounts", id, &acc) == nil && acc.Status == account.StatusActive
}

// ── approvals and notices ───────────────────────────────────────────────────

// ApprovalAsked offers an approval on every channel the person linked with
// notices on.
func (s *Service) ApprovalAsked(ctx context.Context, note gate.ApprovalNote) error {
	actor, err := identity.Parse(note.ActorID)
	if err != nil {
		return nil
	}
	rows, err := s.Bindings(ctx, actor)
	if err != nil {
		return err
	}
	for i := range rows {
		b := &rows[i]
		if !b.Notify {
			continue
		}
		var serr error
		switch b.Provider {
		case cm.Slack:
			serr = s.slackApproval(ctx, b, note)
		case cm.Teams:
			serr = s.teamsApproval(ctx, b, note)
		case cm.Twilio:
			serr = s.smsApproval(ctx, b, note)
		}
		if serr != nil {
			s.L.Warn("approval not offered", "provider", b.Provider, "error", serr)
		}
	}
	return nil
}

// Notify sends a notice (a brief, a finished task) to the person's linked
// channels.
func (s *Service) Notify(ctx context.Context, accountID, text string) error {
	actor, err := identity.Parse(accountID)
	if err != nil {
		return nil
	}
	rows, err := s.Bindings(ctx, actor)
	if err != nil {
		return err
	}
	for i := range rows {
		b := &rows[i]
		if !b.Notify {
			continue
		}
		switch b.Provider {
		case cm.Slack:
			_ = s.slackPost(ctx, b.Conversation, text, "", nil)
		case cm.Teams:
			_ = s.teamsSend(ctx, b, map[string]any{"type": "message", "text": text})
		case cm.Twilio:
			_ = s.smsSend(ctx, b.External, text)
		}
	}
	return nil
}

func answerWord(answer string) string {
	return map[string]string{"once": "Allowed once", "always": "Always allowed", "refuse": "Refused"}[answer]
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func approvalText(note gate.ApprovalNote) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", note.Summary)
	if len(note.Recipients) > 0 {
		fmt.Fprintf(&b, "To: %s\n", strings.Join(note.Recipients, ", "))
	}
	if note.Text != "" {
		fmt.Fprintf(&b, "Says: %s\n", clip(note.Text, 600))
	}
	fmt.Fprintf(&b, "Asked by rule: %s", note.Rule)
	return b.String()
}

// ── bridges ─────────────────────────────────────────────────────────────────

type spacesBridge struct{ K api.Kernel }

func (b spacesBridge) HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error) {
	var out *space.Space
	err := bridge.Invoke(ctx, b.K, "spaces", "HomeSpace", []any{ctx, owner}, &out)
	return out, err
}

func (b spacesBridge) RunScheduledTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error) {
	var out string
	err := bridge.Invoke(ctx, b.K, "spaces", "RunScheduledTask", []any{ctx, spaceID, roomID, actor, task}, &out)
	return out, err
}

type governanceBridge struct{ K api.Kernel }

func (b governanceBridge) Answer(ctx context.Context, caller identity.ID, approvalID, answer string) error {
	id, err := identity.Parse(approvalID)
	if err != nil {
		return errs.InvalidArgument("invalid approval")
	}
	var out map[string]any
	return bridge.Invoke(ctx, b.K, "governance", "AnswerApproval", []any{ctx, caller, id, answer}, &out)
}
