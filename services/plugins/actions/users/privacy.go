package users

import (
	"context"
	"slices"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Who may reach a person. Each way in has its own setting:
//
//	messages      sending them a message
//	calls_voice   ringing them with a voice call
//	calls_video   ringing them with a video call
//	invites       inviting them to a room
//
// and each is one of:
//
//	everyone  anyone who is not blocked
//	contacts  only people they have sent a message to (someone who merely
//	          messaged them is not a contact: otherwise one unwanted message
//	          would make a stranger one; for messages, that means the other
//	          person has to have written to you first)
//	nobody    no one
//
// Blocking always wins. The rules are applied here on the node, where a call
// starts and where an invitation is made, so no app can get round them.

const (
	audienceEveryone = "everyone"
	audienceContacts = "contacts"
	audienceNobody   = "nobody"
)

var audiences = []string{audienceEveryone, audienceContacts, audienceNobody}

// Everything starts open to everyone (as it was before the choices existed);
// each person narrows it.
const defaultAudience = audienceEveryone

// privacyPrefs is one person's choices; an empty field is the default.
type privacyPrefs struct {
	ID         string    `db:"id" json:"id"`
	CallsVoice string    `db:"calls_voice" json:"-"`
	CallsVideo string    `db:"calls_video" json:"-"`
	Invites    string    `db:"invites" json:"-"`
	Messages   string    `db:"messages" json:"-"`
	UpdatedAt  time.Time `db:"updated_at" json:"-"`
}

func pick(chosen, fallback string) string {
	if slices.Contains(audiences, chosen) {
		return chosen
	}
	return fallback
}

// privacyOf reads a person's choices, defaults filled in.
func (s *Service) privacyOf(ctx context.Context, account identity.ID) privacyPrefs {
	var p privacyPrefs
	if err := s.R.GetString(ctx, "privacy_prefs", account.String(), &p); err != nil {
		p = privacyPrefs{ID: account.String()}
	}
	p.CallsVoice, p.CallsVideo, p.Invites, p.Messages = pick(p.CallsVoice, defaultAudience), pick(p.CallsVideo, defaultAudience), pick(p.Invites, defaultAudience), pick(p.Messages, defaultAudience)
	return p
}

// isContact says whether `owner` has sent `other` a message: the people one has chatted with.
func (s *Service) isContact(ctx context.Context, owner, other identity.ID) bool {
	if owner == other {
		return true
	}
	var rows []struct {
		ID string `db:"id"`
	}
	f := database.Filter{Equal: map[string]any{"from_id": owner.String(), "to_id": other.String()}, Limit: 1}
	return s.R.List(ctx, "directs", f, &rows) == nil && len(rows) > 0
}

// allowed applies one audience choice to a person trying to reach `owner`.
func (s *Service) allowed(ctx context.Context, owner, who identity.ID, audience string) bool {
	switch audience {
	case audienceEveryone:
		return true
	case audienceContacts:
		return s.isContact(ctx, owner, who)
	}
	return false
}

// callAllowed says whether `caller` may ring `callee`. The refusal is the same
// whichever setting caused it, so a caller cannot learn who has blocked them or
// what they chose.
func (s *Service) callAllowed(ctx context.Context, caller, callee identity.ID, video bool) error {
	p := s.privacyOf(ctx, callee)
	audience := p.CallsVoice
	if video {
		audience = p.CallsVideo
	}
	if !s.allowed(ctx, callee, caller, audience) {
		return errs.Conflict("this person can't be called")
	}
	return nil
}

// messageAllowed says whether `sender` may message `recipient`. The refusal is
// the same words as a block's, so a sender cannot tell which it was or what was
// chosen. Your own notes, and agents and tools (which have no choices), are open.
func (s *Service) messageAllowed(ctx context.Context, sender, recipient identity.ID) error {
	if sender == recipient {
		return nil
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", recipient, &acc); err != nil || acc.Kind != account.KindUser {
		return nil
	}
	if !s.allowed(ctx, recipient, sender, s.privacyOf(ctx, recipient).Messages) {
		return errs.New(errs.CodePermission, "You can't message this person.")
	}
	return nil
}

// AllowsInvite says whether `inviter` may invite `invitee` to a room. The rooms
// service asks it when an invitation is made. Agents and tools have no
// choices to honour.
func (s *Service) AllowsInvite(ctx context.Context, inviter, invitee identity.ID) error {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", invitee, &acc); err != nil || acc.Kind != account.KindUser {
		return nil
	}
	if inviter == invitee {
		return nil
	}
	if blocked, _, err := s.directBlocked(ctx, inviter, invitee); err == nil && blocked {
		return errs.New(errs.CodePermission, "this person can't be invited")
	}
	if !s.allowed(ctx, invitee, inviter, s.privacyOf(ctx, invitee).Invites) {
		return errs.New(errs.CodePermission, "this person can't be invited")
	}
	return nil
}

func privacyActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "privacy_get", Summary: "Who may call and invite the caller", Handler: s.privacyGet},
		helper.Action{Namespace: "users", Name: "privacy_set", Summary: "Choose who may call and invite the caller", Handler: s.privacySet},
	}
}

func privacyView(p privacyPrefs) map[string]any {
	return map[string]any{"messages": p.Messages, "calls_voice": p.CallsVoice, "calls_video": p.CallsVideo, "invites": p.Invites}
}

func (s *Service) privacyGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	return helper.JSON(privacyView(s.privacyOf(ctx, req.Caller.ID)))
}

// privacySet changes the choices it names and leaves the others as they are.
func (s *Service) privacySet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Messages   *string `json:"messages"`
		CallsVoice *string `json:"calls_voice"`
		CallsVideo *string `json:"calls_video"`
		Invites    *string `json:"invites"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p := s.privacyOf(ctx, req.Caller.ID)
	for _, c := range []struct {
		to   *string
		from *string
	}{{&p.Messages, in.Messages}, {&p.CallsVoice, in.CallsVoice}, {&p.CallsVideo, in.CallsVideo}, {&p.Invites, in.Invites}} {
		if c.from == nil {
			continue
		}
		if !slices.Contains(audiences, *c.from) {
			return nil, errs.InvalidArgument("choose everyone, contacts or nobody")
		}
		*c.to = *c.from
	}
	p.UpdatedAt = time.Now().UTC()
	err := s.R.DB.Create(ctx, "privacy_prefs", p.ID, &p)
	if errs.CodeOf(err) == errs.CodeAlreadyExists || errs.CodeOf(err) == errs.CodeConflict {
		err = s.R.DB.Update(ctx, "privacy_prefs", p.ID, &p)
	}
	if err != nil {
		return nil, err
	}
	return helper.JSON(privacyView(p))
}
