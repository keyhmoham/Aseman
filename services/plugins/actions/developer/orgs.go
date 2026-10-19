package developer

import (
	"context"
	"sort"
	"strings"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// PersonalOrg is how the console names the person's own organization.
const PersonalOrg = "personal"

// What each role may do (the console's table, which this mirrors).
var can = map[string][]string{
	models.RoleOwner:     {"keys", "resources", "members", "billing", "settings", "delete"},
	models.RoleAdmin:     {"keys", "resources", "members", "billing", "settings"},
	models.RoleDeveloper: {"keys", "resources"},
	models.RoleViewer:    {},
}

// Scope is an organization as one person sees it.
type Scope struct {
	// Org is the organization's id: the team's, or the account's for the
	// personal one. Its wallet is owned by this id.
	Org      identity.ID
	Personal bool
	Name     string
	Role     string
}

// Can reports whether the person's role allows an action.
func (sc Scope) Can(action string) bool {
	for _, a := range can[sc.Role] {
		if a == action {
			return true
		}
	}
	return false
}

// Require refuses an action the person's role does not allow.
func (sc Scope) Require(action string) error {
	if !sc.Can(action) {
		return errs.Permission("your role in " + sc.Name + " does not allow this")
	}
	return nil
}

// Scope resolves an organization reference ("personal" or a team's id) for a
// person. A team the person is not an active member of does not exist to them.
func (s *Service) Scope(ctx context.Context, caller identity.ID, ref string) (Scope, error) {
	if caller.IsZero() {
		return Scope{}, errs.Unauthenticated("authentication required")
	}
	ref = strings.TrimSpace(ref)
	if ref == "" || ref == PersonalOrg {
		return Scope{Org: caller, Personal: true, Name: "Personal", Role: models.RoleOwner}, nil
	}
	id, err := identity.Parse(ref)
	if err != nil {
		return Scope{}, errs.NotFound("organization")
	}
	var org models.Org
	if err := s.R.Get(ctx, "dev_orgs", id, &org); err != nil {
		return Scope{}, errs.NotFound("organization")
	}
	member, err := s.member(ctx, id, caller)
	if err != nil || member.Status != models.StatusActive {
		return Scope{}, errs.NotFound("organization")
	}
	return Scope{Org: id, Name: org.Name, Role: member.Role}, nil
}

// ScopeOf is the scope of an organization by its id alone, as the API sees it
// (a key belongs to one organization; no person is involved).
func (s *Service) ScopeOf(ctx context.Context, org identity.ID) (name string, personal bool, err error) {
	var row models.Org
	if err := s.R.Get(ctx, "dev_orgs", org, &row); err == nil {
		return row.Name, false, nil
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", org, &acc); err != nil {
		return "", false, errs.NotFound("organization")
	}
	return "Personal", true, nil
}

func (s *Service) member(ctx context.Context, org, who identity.ID) (*models.Member, error) {
	var list []models.Member
	if err := s.R.List(ctx, "dev_members", database.Filter{Equal: map[string]any{"org_id": org.String(), "account_id": who.String()}}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("member")
	}
	return &list[0], nil
}

func (s *Service) members(ctx context.Context, org identity.ID) ([]models.Member, error) {
	var list []models.Member
	if err := s.R.List(ctx, "dev_members", database.Filter{Equal: map[string]any{"org_id": org.String()}, OrderBy: "created_at", Asc: true}, &list); err != nil {
		return nil, err
	}
	return list, nil
}

// OrgView is an organization as the console shows it.
type OrgView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	CreatedAt string `json:"createdAt"`
	Role      string `json:"role"`
}

// MemberView is a person in an organization as the console shows them.
type MemberView struct {
	ID       string `json:"id"`
	Handle   string `json:"handle"`
	Name     string `json:"name,omitempty"`
	Role     string `json:"role"`
	Status   string `json:"status"`
	JoinedAt string `json:"joinedAt"`
	You      bool   `json:"you,omitempty"`
}

// InviteView is an invitation waiting for the person to answer.
type InviteView struct {
	Org       string `json:"org"`
	Name      string `json:"name"`
	Role      string `json:"role"`
	InvitedBy string `json:"invitedBy"`
	At        string `json:"at"`
}

// Orgs lists the organizations a person works in: their own, then the teams
// they are an active member of.
func (s *Service) Orgs(ctx context.Context, caller identity.ID) ([]OrgView, error) {
	out := []OrgView{{ID: PersonalOrg, Name: "Personal", Kind: "personal", Role: models.RoleOwner, CreatedAt: "1970-01-01T00:00:00Z"}}
	var mine []models.Member
	if err := s.R.List(ctx, "dev_members", database.Filter{Equal: map[string]any{"account_id": caller.String(), "status": models.StatusActive}}, &mine); err != nil {
		return nil, err
	}
	var teams []OrgView
	for _, m := range mine {
		var org models.Org
		if err := s.R.Get(ctx, "dev_orgs", m.OrgID, &org); err != nil {
			continue // the organization was deleted
		}
		teams = append(teams, OrgView{ID: org.ID.String(), Name: org.Name, Kind: "team", CreatedAt: stamp(org.CreatedAt), Role: m.Role})
	}
	sort.SliceStable(teams, func(i, j int) bool { return strings.ToLower(teams[i].Name) < strings.ToLower(teams[j].Name) })
	return append(out, teams...), nil
}

// CreateOrg makes a team organization owned by the caller, with a wallet of
// its own (empty: it is funded from a person's balance).
func (s *Service) CreateOrg(ctx context.Context, caller identity.ID, name string) (*OrgView, error) {
	name = strings.TrimSpace(name)
	if len([]rune(name)) < 2 || len([]rune(name)) > 60 {
		return nil, errs.InvalidArgument("Give the organization a name of 2 to 60 characters.")
	}
	existing, err := s.Orgs(ctx, caller)
	if err != nil {
		return nil, err
	}
	for _, o := range existing {
		if strings.EqualFold(o.Name, name) {
			return nil, errs.New(errs.CodeAlreadyExists, "You already have an organization with that name.")
		}
	}
	id, err := s.newID()
	if err != nil {
		return nil, err
	}
	now := s.now()
	org := &models.Org{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, Name: name, OwnerID: caller}
	if err := s.R.CreateID(ctx, "dev_orgs", id, org); err != nil {
		return nil, err
	}
	if err := s.Fin.EnsureWallet(ctx, id); err != nil {
		_ = s.R.Delete(ctx, "dev_orgs", id)
		return nil, err
	}
	mid, err := s.newID()
	if err != nil {
		return nil, err
	}
	owner := &models.Member{Entity: entity.Entity{ID: mid, CreatedAt: now, UpdatedAt: now}, OrgID: id, AccountID: caller, Handle: s.handleOf(ctx, caller), Role: models.RoleOwner, Status: models.StatusActive, InvitedBy: caller}
	if err := s.R.CreateID(ctx, "dev_members", mid, owner); err != nil {
		return nil, err
	}
	return &OrgView{ID: id.String(), Name: name, Kind: "team", CreatedAt: stamp(now), Role: models.RoleOwner}, nil
}

// RenameOrg renames a team organization.
func (s *Service) RenameOrg(ctx context.Context, sc Scope, name string) error {
	if sc.Personal {
		return errs.InvalidArgument("Your personal organization cannot be renamed.")
	}
	if err := sc.Require("settings"); err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if len([]rune(name)) < 2 || len([]rune(name)) > 60 {
		return errs.InvalidArgument("Give the organization a name of 2 to 60 characters.")
	}
	var org models.Org
	if err := s.R.Get(ctx, "dev_orgs", sc.Org, &org); err != nil {
		return err
	}
	org.Name, org.UpdatedAt = name, s.now()
	return s.R.Update(ctx, "dev_orgs", sc.Org, &org)
}

// DeleteOrg deletes a team organization: what is left in its wallet goes back
// to the person deleting it, its keys stop working and its records go.
func (s *Service) DeleteOrg(ctx context.Context, caller identity.ID, sc Scope) error {
	if sc.Personal {
		return errs.InvalidArgument("Your personal organization cannot be deleted.")
	}
	if err := sc.Require("delete"); err != nil {
		return err
	}
	if w, err := s.Fin.GetWallet(ctx, sc.Org); err == nil && w.Available() > 0 {
		if _, err := s.Fin.Transfer(ctx, sc.Org, caller, w.Available()); err != nil {
			return err
		}
	}
	// Machines cost money and files take room: neither outlives its organization.
	var computers []models.Computer
	if err := s.R.List(ctx, "dev_computers", database.Filter{Equal: map[string]any{"org_id": sc.Org.String()}}, &computers); err != nil {
		return err
	}
	for _, c := range computers {
		if err := s.DeleteComputer(ctx, sc.Org, c.ID.String()); err != nil {
			return err
		}
	}
	var stored []models.File
	if err := s.R.List(ctx, "dev_files", database.Filter{Equal: map[string]any{"org_id": sc.Org.String()}}, &stored); err != nil {
		return err
	}
	for _, f := range stored {
		if err := s.DeleteFile(ctx, sc.Org, f.ID.String()); err != nil {
			return err
		}
	}
	for _, table := range []string{"dev_keys", "dev_members", "dev_logs"} {
		var ids []struct {
			ID identity.ID `db:"id" json:"id"`
		}
		if err := s.R.List(ctx, table, database.Filter{Equal: map[string]any{"org_id": sc.Org.String()}}, &ids); err != nil {
			return err
		}
		for _, row := range ids {
			if err := s.R.DB.Delete(ctx, table, row.ID.String()); err != nil {
				return err
			}
		}
	}
	_ = s.R.DB.Delete(ctx, "dev_settings", sc.Org.String())
	return s.R.Delete(ctx, "dev_orgs", sc.Org)
}

func (s *Service) handleOf(ctx context.Context, id identity.ID) string {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", id, &acc); err != nil {
		return ""
	}
	return acc.Handle
}

func (s *Service) accountByHandle(ctx context.Context, handle string) (*account.Account, error) {
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &list); err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].Kind == account.KindUser && list[i].Status == account.StatusActive {
			return &list[i], nil
		}
	}
	return nil, errs.InvalidArgument("Nobody has the username @" + handle + ".")
}

func validRole(role string) bool {
	return role == models.RoleOwner || role == models.RoleAdmin || role == models.RoleDeveloper || role == models.RoleViewer
}

// Members lists an organization's people.
func (s *Service) Members(ctx context.Context, caller identity.ID, sc Scope) ([]MemberView, error) {
	if sc.Personal {
		return []MemberView{{ID: caller.String(), Handle: s.handleOf(ctx, caller), Role: models.RoleOwner, Status: models.StatusActive, You: true}}, nil
	}
	list, err := s.members(ctx, sc.Org)
	if err != nil {
		return nil, err
	}
	out := make([]MemberView, 0, len(list))
	for _, m := range list {
		out = append(out, MemberView{ID: m.ID.String(), Handle: m.Handle, Role: m.Role, Status: m.Status, JoinedAt: stamp(m.CreatedAt), You: m.AccountID == caller})
	}
	return out, nil
}

// Invite adds a person by username. They see the invitation and join when they
// accept it.
func (s *Service) Invite(ctx context.Context, caller identity.ID, sc Scope, handle, role string) (*MemberView, error) {
	if sc.Personal {
		return nil, errs.InvalidArgument("Make an organization to work with other people.")
	}
	if err := sc.Require("members"); err != nil {
		return nil, err
	}
	if !validRole(role) || (role == models.RoleOwner && sc.Role != models.RoleOwner) {
		return nil, errs.InvalidArgument("Choose a role you can give.")
	}
	handle = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(handle), "@"))
	acc, err := s.accountByHandle(ctx, handle)
	if err != nil {
		return nil, err
	}
	if _, err := s.member(ctx, sc.Org, acc.ID); err == nil {
		return nil, errs.New(errs.CodeAlreadyExists, "@"+handle+" is already in this organization.")
	}
	id, err := s.newID()
	if err != nil {
		return nil, err
	}
	now := s.now()
	m := &models.Member{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OrgID: sc.Org, AccountID: acc.ID, Handle: acc.Handle, Role: role, Status: models.StatusInvited, InvitedBy: caller}
	if err := s.R.CreateID(ctx, "dev_members", id, m); err != nil {
		return nil, err
	}
	return &MemberView{ID: id.String(), Handle: acc.Handle, Role: role, Status: models.StatusInvited, JoinedAt: stamp(now)}, nil
}

// owners counts the active owners of an organization.
func owners(list []models.Member) int {
	n := 0
	for _, m := range list {
		if m.Role == models.RoleOwner && m.Status == models.StatusActive {
			n++
		}
	}
	return n
}

// SetRole changes a person's role. An organization always keeps an owner.
func (s *Service) SetRole(ctx context.Context, sc Scope, memberID, role string) error {
	if err := sc.Require("members"); err != nil {
		return err
	}
	if !validRole(role) || (role == models.RoleOwner && sc.Role != models.RoleOwner) {
		return errs.InvalidArgument("Choose a role you can give.")
	}
	m, list, err := s.findMember(ctx, sc, memberID)
	if err != nil {
		return err
	}
	if m.Role == models.RoleOwner && sc.Role != models.RoleOwner {
		return errs.Permission("Only an owner can change an owner's role.")
	}
	if m.Role == models.RoleOwner && role != models.RoleOwner && owners(list) <= 1 {
		return errs.InvalidArgument("An organization needs at least one owner.")
	}
	m.Role, m.UpdatedAt = role, s.now()
	return s.R.Update(ctx, "dev_members", m.ID, m)
}

func (s *Service) findMember(ctx context.Context, sc Scope, memberID string) (*models.Member, []models.Member, error) {
	id, err := identity.Parse(memberID)
	if err != nil {
		return nil, nil, errs.NotFound("member")
	}
	list, err := s.members(ctx, sc.Org)
	if err != nil {
		return nil, nil, err
	}
	for i := range list {
		if list[i].ID == id {
			return &list[i], list, nil
		}
	}
	return nil, nil, errs.NotFound("member")
}

// RemoveMember removes a person, or lets someone leave. An organization always
// keeps an owner.
func (s *Service) RemoveMember(ctx context.Context, caller identity.ID, sc Scope, memberID string) error {
	m, list, err := s.findMember(ctx, sc, memberID)
	if err != nil {
		return err
	}
	if m.AccountID != caller {
		if err := sc.Require("members"); err != nil {
			return err
		}
		if m.Role == models.RoleOwner && sc.Role != models.RoleOwner {
			return errs.Permission("Only an owner can remove an owner.")
		}
	}
	if m.Role == models.RoleOwner && m.Status == models.StatusActive && owners(list) <= 1 {
		return errs.InvalidArgument("An organization needs at least one owner. Make someone else an owner first, or delete the organization.")
	}
	return s.R.Delete(ctx, "dev_members", m.ID)
}

// Invites lists the invitations waiting for a person.
func (s *Service) Invites(ctx context.Context, caller identity.ID) ([]InviteView, error) {
	var list []models.Member
	if err := s.R.List(ctx, "dev_members", database.Filter{Equal: map[string]any{"account_id": caller.String(), "status": models.StatusInvited}}, &list); err != nil {
		return nil, err
	}
	out := []InviteView{}
	for _, m := range list {
		var org models.Org
		if err := s.R.Get(ctx, "dev_orgs", m.OrgID, &org); err != nil {
			continue
		}
		out = append(out, InviteView{Org: org.ID.String(), Name: org.Name, Role: m.Role, InvitedBy: s.handleOf(ctx, m.InvitedBy), At: stamp(m.CreatedAt)})
	}
	return out, nil
}

// Respond accepts or declines an invitation.
func (s *Service) Respond(ctx context.Context, caller identity.ID, org string, accept bool) error {
	id, err := identity.Parse(org)
	if err != nil {
		return errs.NotFound("invitation")
	}
	m, err := s.member(ctx, id, caller)
	if err != nil || m.Status != models.StatusInvited {
		return errs.NotFound("invitation")
	}
	if !accept {
		return s.R.Delete(ctx, "dev_members", m.ID)
	}
	m.Status, m.UpdatedAt = models.StatusActive, s.now()
	return s.R.Update(ctx, "dev_members", m.ID, m)
}
