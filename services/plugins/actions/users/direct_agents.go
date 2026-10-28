package users

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// agentAccount reports the bot behind an account a person can talk to
// directly: an agent (a conversation with it) or an app (asked in plain
// words, as the person). The project's computer is not one.
func (s *Service) agentAccount(ctx context.Context, accountID identity.ID) (identity.ID, bool) {
	var bots []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"account_id": accountID.String()}, Limit: 1}, &bots); err != nil || len(bots) == 0 {
		return identity.ID{}, false
	}
	b := &bots[0]
	if b.Kind == bot.KindAgent || (b.Kind == bot.KindTool && b.IsToolBackend() && !b.IsSandbox()) {
		return b.ID, true
	}
	return identity.ID{}, false
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
