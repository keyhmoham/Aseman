// Package message implements the message namespace: the universal packet
// transport between users and bots. It provides fire-and-forget delivery
// (message.send), request/response exchanges (message.ask / message.respond)
// and inbox listing. The ask/respond protocol is what miniapp frontends use to
// call their wasm backends and agents use to answer questions.
package message

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// BotMessenger is the subset of the bots service the message namespace needs
// to deliver asks to bot VMs (langchain agents and wasm miniapp backends).
type BotMessenger interface {
	SendMessage(ctx context.Context, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error)
	// BillUsage charges the customer for a bot execution (per-minute cost).
	BillUsage(ctx context.Context, customer, botID identity.ID, seconds int64, desc string) error
	// EnsureFunds hard-blocks execution when the customer cannot cover the
	// bot's minimum metered cost.
	EnsureFunds(ctx context.Context, customer, botID identity.ID) error
	// IsTradera reports whether the target is the built-in orchestrator agent.
	IsTradera(ctx context.Context, botID identity.ID) (bool, error)
	// RunTradera executes a task with the built-in orchestrator.
	RunTradera(ctx context.Context, caller identity.ID, task string) (map[string]any, error)
}

// AttachmentResolver resolves and authorizes file ids attached to an ask so the
// target bot (or user) sees what was shared. Implemented by the spaces service.
type AttachmentResolver interface {
	ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error)
}

// Service implements packet transport operations.
type Service struct {
	K     api.Kernel
	R     *repo.Repo
	Bots  BotMessenger
	Files AttachmentResolver
	L     *logger.Logger
}

// NewService builds the message service.
func NewService(k api.Kernel, r *repo.Repo, bots BotMessenger, log *logger.Logger) *Service {
	return &Service{K: k, R: r, Bots: bots, L: log.Named("message")}
}

// ResolveAttachments resolves a list of file ids into VM-facing attachment
// descriptors, delegating the file lookup and authorization to the spaces
// service when wired.
func (s *Service) ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error) {
	if s.Files == nil {
		return nil, nil
	}
	return s.Files.ResolveAttachments(ctx, caller, ids)
}

// SendPacket stores a fire-and-forget packet from one account to another.
func (s *Service) SendPacket(ctx context.Context, from, to identity.ID, body, payload string) (*message.Packet, error) {
	if body == "" && payload == "" {
		return nil, errs.InvalidArgument("message body required")
	}
	if to.IsZero() {
		return nil, errs.InvalidArgument("recipient (to) required")
	}
	rec, err := s.resolve(ctx, to)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	p := &message.Packet{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   from, To: rec.account.ID,
		Kind: message.PacketMessage, Status: message.StatusSent,
		Body: body, Payload: payload, ReceivedAt: now,
	}
	if err := s.R.CreateID(ctx, "packets", id, p); err != nil {
		return nil, err
	}
	return p, nil
}

// Ask sends a request to a user or bot and, when the target is a bot,
// synchronously routes it to the bot VM. For user targets the ask is stored
// and answered later via Respond; the caller polls message.get with the
// returned correlation id. The optional history carries earlier turns of the
// conversation so conversational bot VMs remember the context, and
// [attachments] are files sent with the ask (agents see what was shared).
func (s *Service) Ask(ctx context.Context, from, to identity.ID, body, payload string, attachments []vmm.FileAttachment, history []vmm.ChatMessage, timeout time.Duration) (*message.Packet, string, error) {
	if to.IsZero() {
		return nil, "", errs.InvalidArgument("recipient (to) required")
	}
	if body == "" && payload == "" {
		return nil, "", errs.InvalidArgument("ask body required")
	}
	rec, err := s.resolve(ctx, to)
	if err != nil {
		return nil, "", err
	}
	now := time.Now().UTC()
	askID, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, "", err
	}
	ask := &message.Packet{
		Entity: entity.Entity{ID: askID, CreatedAt: now, UpdatedAt: now},
		From:   from, To: rec.account.ID,
		Kind: message.PacketAsk, Status: message.StatusRequested,
		Body: body, Payload: payload,
	}
	if rec.account.Kind != account.KindBot {
		// Asynchronous user-to-user (or user-to-async-bot) ask.
		if err := s.R.CreateID(ctx, "packets", askID, ask); err != nil {
			return nil, "", err
		}
		return ask, "", nil
	}
	// Synchronous bot ask: route to the bot VM (via its bot record id).
	// Hard enforcement: the caller must be able to pay before the bot runs.
	if err := s.Bots.EnsureFunds(ctx, from, rec.botRecord); err != nil {
		return nil, "", err
	}
	rctx := ctx
	if timeout > 0 {
		var cancel context.CancelFunc
		rctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	start := time.Now()
	reply, serr := s.Bots.SendMessage(rctx, rec.botRecord, body, attachments, history)
	if serr != nil {
		ask.Status = message.StatusFailed
		_ = s.R.CreateID(ctx, "packets", askID, ask)
		return nil, "", errs.Wrap(errs.CodeVMM, serr, "bot ask failed")
	}
	if err := s.Bots.BillUsage(ctx, from, rec.botRecord, int64(time.Since(start).Seconds()), "message ask"); err != nil {
		return nil, "", err
	}
	ask.Status = message.StatusAnswered
	ask.RepliedAt = time.Now().UTC()
	ask.ReceivedAt = ask.RepliedAt
	if err := s.R.CreateID(ctx, "packets", askID, ask); err != nil {
		return nil, "", err
	}
	respID, err := s.storeResponse(ctx, rec.account.ID, from, askID, reply, "")
	if err != nil {
		return nil, "", err
	}
	return ask, respID, nil
}

// Respond answers a previously requested ask. Only the ask recipient may
// answer, so bots can answer asks sent to them and users can answer asks
// between users.
func (s *Service) Respond(ctx context.Context, responder identity.ID, correlation identity.ID, body, payload string) error {
	ask := &message.Packet{}
	if err := s.R.Get(ctx, "packets", correlation, ask); err != nil {
		return err
	}
	if ask.Kind != message.PacketAsk {
		return errs.InvalidArgument("correlation does not reference an ask")
	}
	if ask.Status == message.StatusAnswered {
		return errs.Conflict("ask already answered")
	}
	if ask.To != responder {
		return errs.Permission("only the ask recipient can respond")
	}
	_, err := s.storeResponse(ctx, responder, ask.From, correlation, body, payload)
	return err
}

// storeResponse records the answer packet and marks the ask answered.
func (s *Service) storeResponse(ctx context.Context, from, to identity.ID, corr identity.ID, body, payload string) (string, error) {
	now := time.Now().UTC()
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	resp := &message.Packet{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   from, To: to,
		Kind: message.PacketResponse, Status: message.StatusSent,
		Body: body, Payload: payload, CorrelationID: corr, ReceivedAt: now,
	}
	if err := s.R.CreateID(ctx, "packets", id, resp); err != nil {
		return "", err
	}
	ask := &message.Packet{}
	if err := s.R.Get(ctx, "packets", corr, ask); err == nil && ask.Kind == message.PacketAsk {
		ask.Status = message.StatusAnswered
		ask.RepliedAt = now
		ask.UpdatedAt = now
		_ = s.R.Update(ctx, "packets", corr, ask)
	}
	return id.String(), nil
}

// List returns packets the caller sent to or received from a peer (or anyone),
// newest first, with offset-based pagination.
func (s *Service) List(ctx context.Context, caller identity.ID, peer identity.ID, limit, offset int) ([]message.Packet, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	need := limit + offset
	var incoming, outgoing []message.Packet
	if err := s.R.List(ctx, "packets", database.Filter{
		Equal: map[string]any{"to_id": caller.String()}, OrderBy: "created_at", Asc: false, Limit: need,
	}, &incoming); err != nil {
		return nil, err
	}
	if err := s.R.List(ctx, "packets", database.Filter{
		Equal: map[string]any{"from_id": caller.String()}, OrderBy: "created_at", Asc: false, Limit: need,
	}, &outgoing); err != nil {
		return nil, err
	}
	if !peer.IsZero() {
		filter := func(list []message.Packet, field func(*message.Packet) identity.ID) []message.Packet {
			var kept []message.Packet
			for i := range list {
				if field(&list[i]) == peer {
					kept = append(kept, list[i])
				}
			}
			return kept
		}
		incoming = filter(incoming, func(p *message.Packet) identity.ID { return p.From })
		outgoing = filter(outgoing, func(p *message.Packet) identity.ID { return p.To })
	}
	out := mergeDesc(incoming, outgoing)
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// Requests returns unanswered asks addressed to the caller (bot or user inbox).
func (s *Service) Requests(ctx context.Context, caller identity.ID) ([]message.Packet, error) {
	var out []message.Packet
	if err := s.R.List(ctx, "packets", database.Filter{
		Equal: map[string]any{
			"to_id": caller.String(), "kind": string(message.PacketAsk), "status": string(message.StatusRequested),
		},
		OrderBy: "created_at", Asc: false, Limit: 100,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Get returns a single packet the caller is party to, attaching the response
// body when it is an answered ask.
func (s *Service) Get(ctx context.Context, caller identity.ID, id identity.ID) (map[string]any, error) {
	p := &message.Packet{}
	if err := s.R.Get(ctx, "packets", id, p); err != nil {
		return nil, err
	}
	if p.From != caller && p.To != caller {
		return nil, errs.Permission("not a party to this packet")
	}
	out := map[string]any{
		"id": p.ID.String(), "from_id": p.From.String(), "to_id": p.To.String(),
		"kind": p.Kind, "status": p.Status, "body": p.Body,
		"payload": p.Payload, "correlation_id": p.CorrelationID.String(),
		"created_at": p.CreatedAt, "replied_at": p.RepliedAt,
	}
	if p.Kind == message.PacketAsk && p.Status == message.StatusAnswered {
		var resp []message.Packet
		if err := s.R.List(ctx, "packets", database.Filter{
			Equal: map[string]any{"correlation_id": p.ID.String(), "kind": string(message.PacketResponse)},
		}, &resp); err == nil && len(resp) > 0 {
			out["response"] = resp[0].Body
			out["response_payload"] = resp[0].Payload
		}
	}
	return out, nil
}

// recipient couples the resolved account with the bot record id when the
// recipient is a bot VM.
type recipient struct {
	account   *account.Account
	botRecord identity.ID
}

// resolve maps a recipient reference (either an account id or a bot record id)
// onto its account, remembering the bot record id for VM routing.
func (s *Service) resolve(ctx context.Context, id identity.ID) (*recipient, error) {
	acc := &account.Account{}
	if err := s.R.Get(ctx, "accounts", id, acc); err == nil {
		if acc.Kind == account.KindBot {
			var bots []bot.Bot
			if err := s.R.List(ctx, "bots", database.Filter{
				Equal: map[string]any{"account_id": id.String()},
			}, &bots); err == nil && len(bots) > 0 {
				return &recipient{account: acc, botRecord: bots[0].ID}, nil
			}
		}
		return &recipient{account: acc}, nil
	}
	b := &bot.Bot{}
	if err := s.R.Get(ctx, "bots", id, b); err == nil {
		if err := s.R.Get(ctx, "accounts", b.AccountID, acc); err == nil {
			return &recipient{account: acc, botRecord: id}, nil
		}
	}
	return nil, errs.NotFound("recipient account not found")
}

// account loads an account by id, verifying it exists.
func (s *Service) account(ctx context.Context, id identity.ID) (*account.Account, error) {
	rec, err := s.resolve(ctx, id)
	if err != nil {
		return nil, err
	}
	return rec.account, nil
}

// mergeDesc merges two already-descending lists into one descending list.
func mergeDesc(a, b []message.Packet) []message.Packet {
	out := make([]message.Packet, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if a[i].CreatedAt.After(b[j].CreatedAt) {
			out = append(out, a[i])
			i++
		} else {
			out = append(out, b[j])
			j++
		}
	}
	out = append(out, a[i:]...)
	out = append(out, b[j:]...)
	return out
}

// BuildActions assembles the message namespace actions.
func BuildActions(s *Service) []api.Action {
	return []api.Action{
		&sendAction{s: s}, &askAction{s: s}, &respondAction{s: s},
		&listAction{s: s}, &getAction{s: s}, &requestsAction{s: s},
	}
}
