// Package enterprise is how an organization runs Aseman for its people:
//
//   - single sign-on with any OpenID Connect provider (authorization code
//     with PKCE and a nonce), required for the provider's email domains if
//     the organization wants;
//   - SCIM 2.0, so the directory creates, updates and removes people and
//     groups; deactivating someone ends their sessions, revokes their Google
//     connection, saved credentials and linked channels, and stops the
//     computers of the projects only they own;
//   - organizations by email domain, whose people join the organization's
//     shared project, and administrators from directory or SSO groups;
//   - SPIFFE workload identity: the agent runtime presents a JWT-SVID from
//     the deployment's SPIRE, checked against the trust domain's bundle on
//     top of its turn token.
package enterprise

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Ports this namespace uses.
type (
	AuthPort interface {
		OAuthSignIn(ctx context.Context, provider string, claims map[string]any) (*account.Account, string, string, bool, error)
		CreateManagedAccount(ctx context.Context, handle, email, password string) (*account.Account, error)
		RevokeSessions(ctx context.Context, owner identity.ID) (int, error)
		SetAccess(ctx context.Context, id identity.ID, status account.Status, role string) (*account.Account, error)
	}
	SpacesPort interface {
		GetSpace(ctx context.Context, id identity.ID) (*space.Space, error)
		Invite(ctx context.Context, inviter, spaceID, roomID, invitee identity.ID, role membership.Role) (*invitation.Invitation, error)
		AcceptInvitation(ctx context.Context, invitee, invID identity.ID) error
		SandboxStop(ctx context.Context, spaceID identity.ID) (map[string]any, error)
	}
	// Revoker is what other namespaces take back from a person who left.
	Revoker interface {
		Revoke(ctx context.Context, accountID identity.ID) []string
	}
)

// Service is the enterprise namespace.
type Service struct {
	K       api.Kernel
	R       *repo.Repo
	L       *logger.Logger
	Auth    AuthPort
	Spaces  SpacesPort
	Revoker Revoker
	HTTP    *http.Client
	keys    *keySets
	now     func() time.Time
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	client := &http.Client{Timeout: 20 * time.Second}
	return &Service{K: k, R: r, L: log.Named("enterprise"), HTTP: client, keys: newKeySets(client), now: time.Now}
}

func (s *Service) master() string { return s.K.Env()["node_private_key"] }

func (s *Service) isAdmin(ctx context.Context, caller identity.ID) bool {
	var acc account.Account
	if s.R.Get(ctx, "accounts", caller, &acc) != nil || acc.Kind != account.KindUser || acc.Status != account.StatusActive {
		return false
	}
	return acc.Role == "admin" || (acc.Handle != "" && acc.Handle == s.K.Env()["admin_handle"])
}

// settings are the node's enterprise settings.
func (s *Service) settings(ctx context.Context) (*em.Settings, bool) {
	id, _ := identity.Parse(em.SettingsID)
	var st em.Settings
	if err := s.R.Get(ctx, "enterprise_settings", id, &st); err != nil {
		now := s.now().UTC()
		return &em.Settings{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}}, false
	}
	return &st, true
}

func (s *Service) saveSettings(ctx context.Context, st *em.Settings, exists bool) error {
	st.UpdatedAt = s.now().UTC()
	if exists {
		return s.R.Update(ctx, "enterprise_settings", st.ID, st)
	}
	return s.R.CreateID(ctx, "enterprise_settings", st.ID, st)
}

func domainOf(email string) string {
	at := strings.LastIndex(email, "@")
	if at < 0 {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(email[at+1:]))
}

// RequiredProvider names the SSO provider an email's domain must sign in
// with, or "" (auth asks before any other sign-in).
func (s *Service) RequiredProvider(ctx context.Context, email string) (string, error) {
	p, ok := s.providerFor(ctx, email)
	if !ok || !p.Required || !p.Enabled {
		return "", nil
	}
	return p.Name, nil
}

// providerFor is the SSO provider for an email's domain.
func (s *Service) providerFor(ctx context.Context, email string) (*em.SSOProvider, bool) {
	domain := domainOf(email)
	if domain == "" {
		return nil, false
	}
	var rows []em.SSOProvider
	if err := s.R.List(ctx, "sso_providers", database.Filter{Equal: map[string]any{"enabled": true}, Limit: 100}, &rows); err != nil {
		return nil, false
	}
	for i := range rows {
		for _, d := range rows[i].Domains {
			if strings.EqualFold(strings.TrimSpace(d), domain) {
				return &rows[i], true
			}
		}
	}
	return nil, false
}

// syncAdmin makes an administrator of someone in an admin group, and takes
// it back from someone who left every admin group.
func (s *Service) syncAdmin(ctx context.Context, id identity.ID, groups, adminGroups []string) {
	if len(adminGroups) == 0 || s.Auth == nil {
		return
	}
	role := "user"
	for _, g := range groups {
		for _, a := range adminGroups {
			if strings.EqualFold(g, a) {
				role = "admin"
			}
		}
	}
	if _, err := s.Auth.SetAccess(ctx, id, "", role); err != nil {
		s.L.Warn("role not synced", "account", id.String(), "error", err)
	}
}

// joinOrganization adds a person to their email domain's organization
// project.
func (s *Service) joinOrganization(ctx context.Context, id identity.ID, email string) {
	org, ok := s.organizationFor(ctx, email)
	if !ok || org.SpaceID == "" || s.Spaces == nil {
		return
	}
	sp, err := identity.Parse(org.SpaceID)
	if err != nil {
		return
	}
	project, err := s.Spaces.GetSpace(ctx, sp)
	if err != nil || project == nil {
		return
	}
	inv, err := s.Spaces.Invite(ctx, project.OwnerID, sp, identity.ID{}, id, membership.RoleMember)
	if err != nil {
		return // already a member, most often
	}
	_ = s.Spaces.AcceptInvitation(ctx, id, inv.ID)
}

func (s *Service) organizationFor(ctx context.Context, email string) (*em.Organization, bool) {
	domain := domainOf(email)
	var rows []em.Organization
	if domain == "" || s.R.List(ctx, "organizations", database.Filter{Limit: 200}, &rows) != nil {
		return nil, false
	}
	for i := range rows {
		for _, d := range rows[i].Domains {
			if strings.EqualFold(d, domain) {
				return &rows[i], true
			}
		}
	}
	return nil, false
}

// Deprovision takes away everything a person who left had: their sessions,
// their Google connection, saved credentials and standing grants, linked
// channels, and the computers of the projects only they own. Their account
// is disabled, never deleted: what they made stays with the organization.
func (s *Service) Deprovision(ctx context.Context, id identity.ID) ([]string, error) {
	done := []string{}
	if s.Auth != nil {
		if _, err := s.Auth.SetAccess(ctx, id, account.StatusDisabled, ""); err != nil {
			return nil, err
		}
		done = append(done, "disabled")
		if n, err := s.Auth.RevokeSessions(ctx, id); err == nil {
			done = append(done, "sessions ended: "+itoa(n))
		}
	}
	if s.Revoker != nil {
		done = append(done, s.Revoker.Revoke(ctx, id)...)
	}
	var owned []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"owner_id": id.String()}, Limit: 500}, &owned); err == nil && s.Spaces != nil {
		stopped := 0
		for _, sp := range owned {
			var members []membership.Membership
			_ = s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": sp.ID.String(), "role": string(membership.RoleOwner)}}, &members)
			others := false
			for _, m := range members {
				if m.MemberID != id {
					others = true
				}
			}
			if others {
				continue
			}
			if _, err := s.Spaces.SandboxStop(ctx, sp.ID); err == nil {
				stopped++
			}
		}
		done = append(done, "computers stopped: "+itoa(stopped))
	}
	return done, nil
}

func itoa(n int) string { return strconv.Itoa(n) }

// ── bridges ─────────────────────────────────────────────────────────────────

type authBridge struct{ K api.Kernel }

func (b authBridge) OAuthSignIn(ctx context.Context, provider string, claims map[string]any) (*account.Account, string, string, bool, error) {
	var acc *account.Account
	var token, priv string
	var isNew bool
	err := bridge.Invoke(ctx, b.K, "auth", "OAuthSignIn", []any{ctx, provider, claims}, &acc, &token, &priv, &isNew)
	return acc, token, priv, isNew, err
}

func (b authBridge) CreateManagedAccount(ctx context.Context, handle, email, password string) (*account.Account, error) {
	var acc *account.Account
	err := bridge.Invoke(ctx, b.K, "auth", "CreateManagedAccount", []any{ctx, handle, email, password}, &acc)
	return acc, err
}

func (b authBridge) RevokeSessions(ctx context.Context, owner identity.ID) (int, error) {
	var n int
	err := bridge.Invoke(ctx, b.K, "auth", "RevokeSessions", []any{ctx, owner}, &n)
	return n, err
}

func (b authBridge) SetAccess(ctx context.Context, id identity.ID, status account.Status, role string) (*account.Account, error) {
	var acc *account.Account
	err := bridge.Invoke(ctx, b.K, "auth", "SetAccess", []any{ctx, id, status, role}, &acc)
	return acc, err
}

type spacesBridge struct{ K api.Kernel }

func (b spacesBridge) GetSpace(ctx context.Context, id identity.ID) (*space.Space, error) {
	var out *space.Space
	err := bridge.Invoke(ctx, b.K, "spaces", "GetSpace", []any{ctx, id}, &out)
	return out, err
}

func (b spacesBridge) Invite(ctx context.Context, inviter, spaceID, roomID, invitee identity.ID, role membership.Role) (*invitation.Invitation, error) {
	var out *invitation.Invitation
	err := bridge.Invoke(ctx, b.K, "spaces", "Invite", []any{ctx, inviter, spaceID, roomID, invitee, role}, &out)
	return out, err
}

func (b spacesBridge) AcceptInvitation(ctx context.Context, invitee, invID identity.ID) error {
	return bridge.Invoke(ctx, b.K, "spaces", "AcceptInvitation", []any{ctx, invitee, invID})
}

func (b spacesBridge) SandboxStop(ctx context.Context, spaceID identity.ID) (map[string]any, error) {
	var out map[string]any
	err := bridge.Invoke(ctx, b.K, "spaces", "SandboxStop", []any{ctx, spaceID}, &out)
	return out, err
}

// revokers asks every namespace that keeps something for a person to take it
// back; one that is not loaded keeps nothing.
type revokers struct{ K api.Kernel }

func (r revokers) Revoke(ctx context.Context, id identity.ID) []string {
	var done []string
	var n int
	if err := bridge.Invoke(ctx, r.K, "governance", "RevokeSecrets", []any{ctx, id}, &n); err == nil {
		done = append(done, "credentials revoked: "+itoa(n))
	}
	if err := bridge.Invoke(ctx, r.K, "google", "RevokeConnection", []any{ctx, id.String()}); err == nil {
		done = append(done, "Google disconnected")
	}
	if err := bridge.Invoke(ctx, r.K, "channels", "RevokeBindings", []any{ctx, id}); err == nil {
		done = append(done, "channels unlinked")
	}
	return done
}
