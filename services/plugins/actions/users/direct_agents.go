package users

import (
	"context"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// agentAccount reports the agent bot behind an account, if the account is an
// agent's. Direct messages to agents are conversations with them.
func (s *Service) agentAccount(ctx context.Context, accountID identity.ID) (identity.ID, bool) {
	var bots []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"account_id": accountID.String()}, Limit: 1}, &bots); err != nil || len(bots) == 0 {
		return identity.ID{}, false
	}
	if bots[0].Kind != bot.KindAgent {
		return identity.ID{}, false
	}
	return bots[0].ID, true
}

// deliverDirect hands a direct message to the agent it was sent to and sends
// the agent's answer back as a direct message. The conversation runs through
// the spaces namespace (the agent works on a space's sandbox): a person's DM
// runs in their home space, an agent's DM inside its run.
func (s *Service) deliverDirect(ctx context.Context, from, agentAccount, botID identity.ID, body string) {
	var reply string
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
