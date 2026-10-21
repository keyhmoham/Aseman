package message

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// sendAction implements message.send: a fire-and-forget packet to a user or bot.
type sendAction struct{ s *Service }

func (a *sendAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "send", Summary: "Send a fire-and-forget packet to a user or bot"}
}
func (a *sendAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		To      string `json:"to"`
		Body    string `json:"body"`
		Payload string `json:"payload,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, errs.InvalidArgument("invalid recipient id")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.To, "message", "send", req); ok {
		return resp, err
	}
	p, err := a.s.SendPacket(ctx, req.Caller.ID, to, in.Body, in.Payload)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"id": p.ID.String(), "ok": true, "status": p.Status})
}

// askAction implements message.ask: a request to a user or bot expecting a response.
type askAction struct{ s *Service }

func (a *askAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "ask", Summary: "Send a request to a user or bot and wait for its response"}
}
func (a *askAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		To          string            `json:"to"`
		Body        string            `json:"body"`
		Payload     string            `json:"payload,omitempty"`
		History     []vmm.ChatMessage `json:"history,omitempty"`
		Timeout     int64             `json:"timeout_sec,omitempty"`
		Attachments []string          `json:"attachments,omitempty"` // file ids sent with the ask
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, errs.InvalidArgument("invalid recipient id")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.To, "message", "ask", req); ok {
		return resp, err
	}
	timeout := time.Duration(0)
	if in.Timeout > 0 {
		timeout = time.Duration(in.Timeout) * time.Second
	}
	// The built-in aseman agent is the workflow orchestrator.
	if isDec, derr := a.s.Bots.IsAseman(ctx, to); derr == nil && isDec {
		result, rerr := a.s.Bots.RunAseman(ctx, req.Caller.ID, in.Body)
		if rerr != nil {
			return nil, rerr
		}
		return helper.JSON(result)
	}
	atts, err := a.s.ResolveAttachments(ctx, req.Caller.ID, in.Attachments)
	if err != nil {
		return nil, err
	}
	ask, respID, err := a.s.Ask(ctx, req.Caller.ID, to, in.Body, in.Payload, atts, in.History, timeout)
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"correlation_id": ask.ID.String(), "status": ask.Status,
		"kind": ask.Kind, "ok": true,
	}
	if respID != "" {
		out["response_id"] = respID
	}
	if ask.Status == "answered" {
		if got, gerr := a.s.Get(ctx, req.Caller.ID, ask.ID); gerr == nil {
			out["response"] = got["response"]
			out["response_payload"] = got["response_payload"]
		}
	}
	return helper.JSON(out)
}

// respondAction implements message.respond: answer an ask directed at the caller.
type respondAction struct{ s *Service }

func (a *respondAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "respond", Summary: "Answer a previously requested ask"}
}
func (a *respondAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Correlation string `json:"correlation"`
		Body        string `json:"body"`
		Payload     string `json:"payload,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	corr, err := identity.Parse(in.Correlation)
	if err != nil {
		return nil, errs.InvalidArgument("invalid correlation id")
	}
	if err := a.s.Respond(ctx, req.Caller.ID, corr, in.Body, in.Payload); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// listAction implements message.list.
type listAction struct{ s *Service }

func (a *listAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "list", Summary: "List packets involving the caller"}
}
func (a *listAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Peer   string `json:"peer,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	var peer identity.ID
	if in.Peer != "" {
		var err error
		peer, err = identity.Parse(in.Peer)
		if err != nil {
			return nil, errs.InvalidArgument("invalid peer id")
		}
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	list, err := a.s.List(ctx, req.Caller.ID, peer, limit, offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"messages": list})
}

// getAction implements message.get.
type getAction struct{ s *Service }

func (a *getAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "get", Summary: "Fetch a single packet by id"}
}
func (a *getAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Message string `json:"message"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("invalid message id")
	}
	got, err := a.s.Get(ctx, req.Caller.ID, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(got)
}

// requestsAction implements message.requests: the caller's unanswered asks.
type requestsAction struct{ s *Service }

func (a *requestsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "message", Name: "requests", Summary: "List unanswered asks addressed to the caller"}
}
func (a *requestsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	list, err := a.s.Requests(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	start := offset
	if start > len(list) {
		start = len(list)
	}
	end := len(list)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return helper.JSON(map[string]any{"requests": list[start:end]})
}
