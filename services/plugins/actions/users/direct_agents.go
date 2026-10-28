package users

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// botOf is the bot behind an account, if the account is a bot's.
func (s *Service) botOf(ctx context.Context, accountID identity.ID) (*bot.Bot, bool) {
	var bots []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"account_id": accountID.String()}, Limit: 1}, &bots); err != nil || len(bots) == 0 {
		return nil, false
	}
	return &bots[0], true
}

// isApp reports an app (not the project's computer).
func isApp(b *bot.Bot) bool { return b.Kind == bot.KindTool && b.IsToolBackend() && !b.IsSandbox() }

// agentAccount reports the bot behind an account that answers direct
// messages: an agent (a conversation with it) or an app (asked in plain
// words, as the person its sender works for).
func (s *Service) agentAccount(ctx context.Context, accountID identity.ID) (identity.ID, bool) {
	b, ok := s.botOf(ctx, accountID)
	if !ok || (b.Kind != bot.KindAgent && !isApp(b)) {
		return identity.ID{}, false
	}
	return b.ID, true
}

// directAllowed refuses a person's direct message to an app: people use apps
// in their projects, and only agents message an app directly.
func (s *Service) directAllowed(ctx context.Context, from, to identity.ID) error {
	target, ok := s.botOf(ctx, to)
	if !ok || !isApp(target) {
		return nil
	}
	if _, fromBot := s.botOf(ctx, from); fromBot {
		return nil
	}
	return errs.Permission(target.Name + " is an app: use it in a project, or ask an agent to")
}

// deliverDirect hands a direct message to the agent it was sent to and sends
// the agent's answer back as a direct message. The conversation runs through
// the spaces namespace (the agent works on a space's sandbox): a person's DM
// runs in their home space, an agent's DM inside its run.
// joinRun makes the delivery part of the run it was started on, if any
// (spaces.JoinRun); outside a run it is left as it is.
func (s *Service) joinRun(ctx context.Context) (context.Context, func()) {
	var joined context.Context
	var leave func()
	if err := bridge.Invoke(ctx, s.K, "spaces", "JoinRun", []any{ctx}, &joined, &leave); err != nil || joined == nil || leave == nil {
		return ctx, func() {}
	}
	return joined, leave
}

func (s *Service) deliverDirect(ctx context.Context, from, agentAccount, botID identity.ID, body string) {
	if ctx.Err() != nil {
		return // its run was stopped
	}
	var reply string
	// Agents and apps are both asked through the spaces namespace, which
	// knows which one the bot is.
	err := bridge.Invoke(ctx, s.K, "spaces", "AskDirect", []any{ctx, from, botID, body, []vmm.FileAttachment(nil)}, &reply)
	if err != nil {
		if s.L != nil {
			s.L.Warn("direct message to agent failed", "bot", botID.String(), "error", err)
		}
		reply = strings.TrimSpace(reply + "\n\n_(I could not finish: " + err.Error() + ")_")
	}
	if strings.TrimSpace(reply) == "" {
		return
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return
	}
	now := time.Now().UTC()
	dm := &message.Direct{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, From: agentAccount, To: from, Body: reply, SentAt: now}
	if err := s.R.CreateID(context.WithoutCancel(ctx), "directs", id, dm); err != nil && s.L != nil {
		s.L.Warn("store agent direct reply", "bot", botID.String(), "error", err)
	}
	s.mirrorDirect(context.WithoutCancel(ctx), agentAccount, from, reply)
}

// mirrorDirect posts a direct message into the pair's direct conversation
// room (the spaces namespace), where the messenger shows it.
func (s *Service) mirrorDirect(ctx context.Context, from, to identity.ID, body string) {
	if err := bridge.Invoke(ctx, s.K, "spaces", "PostDirect", []any{ctx, from, to, body}); err != nil && s.L != nil {
		s.L.Debug("mirror direct message", "from", from.String(), "to", to.String(), "error", err)
	}
}
