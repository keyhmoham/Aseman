// Package talent owns funded human collaboration offers and recovery of their
// membership/settlement transition. Money remains in finance; access in spaces.
package talent

import (
	"context"
	"encoding/json"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/actions/talent/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"time"
)

type Service struct {
	K     api.Kernel
	R     *repo.Repo
	limit limiter
}

func (s *Service) invoke(ctx context.Context, ns, name string, actor identity.ID, payload any) (map[string]any, error) {
	b, e := json.Marshal(payload)
	if e != nil {
		return nil, e
	}
	response, e := s.K.Actions().Dispatch(helper.WithActor(ctx, actor), ns, name, &api.ActionRequest{Caller: api.Caller{ID: actor, Kind: "user"}, Body: b})
	if e != nil {
		return nil, e
	}
	var out map[string]any
	e = json.Unmarshal(response.Body, &out)
	return out, e
}
func (s *Service) create(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Space     string `json:"space"`
		Recipient string `json:"recipient"`
		Amount    int64  `json:"amount"`
		Message   string `json:"message"`
		RequestID string `json:"request_id"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	recipient, e := identity.Parse(in.Recipient)
	if e != nil {
		return nil, e
	}
	if recipient == req.Caller.ID || in.Amount <= 0 || in.RequestID == "" {
		return nil, errs.InvalidArgument("recipient, positive compensation and request_id required")
	}
	var project space.Space
	if e = s.R.Get(ctx, "spaces", sp, &project); e != nil {
		return nil, e
	}
	if e = helper.CheckResourceManager(helper.WithActor(ctx, req.Caller.ID), s.R, sp, identity.ID{}, project.OwnerID, "space.invite"); e != nil {
		return nil, e
	}
	var person account.Account
	if e = s.R.Get(ctx, "accounts", recipient, &person); e != nil {
		return nil, e
	}
	if person.Kind != account.KindUser || person.Status != account.StatusActive {
		return nil, errs.InvalidArgument("recipient is not an active person")
	}
	var profile metadata.Record
	if e = s.R.GetString(ctx, "metadatas", recipient.String(), &profile); e != nil {
		return nil, e
	}
	fields, _ := profile.Tree["profile"].(map[string]any)
	if fields["hireable"] != true || fields["marketStatus"] != "approved" {
		return nil, errs.Permission("person is not approved for hire")
	}
	id, e := identity.Parse(s.K.NodeID().String() + repo.ExecutionKey(req.Caller.ID.String() + "/" + in.RequestID)[16:])
	if e != nil {
		return nil, e
	}
	now := time.Now().UTC()
	o := models.Offer{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: sp, SenderID: req.Caller.ID, RecipientID: recipient, Amount: in.Amount, Message: in.Message, Status: "funding"}
	if e = s.R.CreateID(ctx, "talent_offers", id, &o); e != nil {
		if errs.CodeOf(e) != errs.CodeAlreadyExists {
			return nil, e
		}
		if e = s.R.Get(ctx, "talent_offers", id, &o); e != nil {
			return nil, e
		}
		if o.SpaceID != sp || o.RecipientID != recipient || o.Amount != in.Amount || o.Message != in.Message {
			return nil, errs.Conflict("offer request id already used")
		}
	}
	if e = s.finish(ctx, &o); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "offer": o})
}
func (s *Service) respond(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.ID)
	if e != nil {
		return nil, e
	}
	var o models.Offer
	if e = s.R.Get(ctx, "talent_offers", id, &o); e != nil {
		return nil, e
	}
	if o.RecipientID != req.Caller.ID {
		return nil, errs.Permission("only the offer recipient can respond")
	}
	next := "settling"
	if in.Status == "declined" {
		next = "declining"
	} else if in.Status != "accepted" {
		return nil, errs.InvalidArgument("status must be accepted or declined")
	}
	if o.Status == in.Status {
		return helper.JSON(map[string]any{"ok": true, "offer": o})
	}
	if o.Status != "pending" && o.Status != next {
		return nil, errs.Conflict("offer is not pending")
	}
	if o.Status == "pending" {
		o.Status = next
		o.UpdatedAt = time.Now().UTC()
		changed, e := s.R.CompareAndSwap(ctx, "talent_offers", id.String(), map[string]any{"status": "pending"}, &o)
		if e != nil {
			return nil, e
		}
		if !changed {
			return nil, errs.Conflict("offer changed")
		}
	}
	if e = s.finish(ctx, &o); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "offer": o})
}
func (s *Service) finish(ctx context.Context, o *models.Offer) error {
	lease, e := repo.ClaimExecution(ctx, s.R, s.K.NodeID(), "talent/"+o.ID.String(), time.Minute)
	if e != nil {
		return e
	}
	defer lease.Release(context.WithoutCancel(ctx), s.R)
	if e = s.R.Get(ctx, "talent_offers", o.ID, o); e != nil {
		return e
	}
	switch o.Status {
	case "funding":
		if e = bridge.Invoke(ctx, s.K, "finance", "ReserveEscrow", []any{ctx, o.SenderID, "talent/" + o.ID.String(), o.Amount}); e != nil {
			return e
		}
		if o.InvitationID == "" {
			r, e := s.invoke(ctx, "spaces", "invite", o.SenderID, map[string]any{"space": o.SpaceID.String(), "invitee": o.RecipientID.String(), "role": "member"})
			if e != nil {
				return e
			}
			o.InvitationID, _ = r["invitation_id"].(string)
		}
		now := time.Now().UTC()
		o.FundedAt = &now
		o.Status = "pending"
	case "settling":
		if _, e = s.invoke(ctx, "spaces", "join", o.RecipientID, map[string]any{"space": o.SpaceID.String()}); e != nil {
			return e
		}
		if e = bridge.Invoke(ctx, s.K, "finance", "ResolveEscrow", []any{ctx, o.SenderID, o.RecipientID, "talent/" + o.ID.String(), true}); e != nil {
			return e
		}
		o.Status = "accepted"
		now := time.Now().UTC()
		o.RespondedAt = &now
	case "declining":
		if o.InvitationID != "" {
			_, e = s.invoke(ctx, "spaces", "invitation_decline", o.RecipientID, map[string]any{"invitation": o.InvitationID})
			if e != nil {
				return e
			}
		}
		if e = bridge.Invoke(ctx, s.K, "finance", "ResolveEscrow", []any{ctx, o.SenderID, o.RecipientID, "talent/" + o.ID.String(), false}); e != nil {
			return e
		}
		o.Status = "declined"
		now := time.Now().UTC()
		o.RespondedAt = &now
	default:
		return nil
	}
	o.Error = ""
	o.UpdatedAt = time.Now().UTC()
	return s.R.Update(ctx, "talent_offers", o.ID, o)
}
func (s *Service) list(ctx context.Context, req *api.ActionRequest, project bool) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var rows []models.Offer
	filter := database.Filter{OrderBy: "created_at", Asc: false}
	if project {
		var in struct {
			Space string `json:"space"`
		}
		if e := helper.Decode(req, &in); e != nil {
			return nil, e
		}
		id, e := identity.Parse(in.Space)
		if e != nil {
			return nil, e
		}
		if e = helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, id, identity.ID{}, false); e != nil {
			return nil, e
		}
		filter.Equal = map[string]any{"space_id": id.String()}
	}
	if e := s.R.List(ctx, "talent_offers", filter, &rows); e != nil {
		return nil, e
	}
	out := []map[string]any{}
	names := map[string]string{}
	handles := map[string]string{}
	for _, o := range rows {
		if project || o.SenderID == req.Caller.ID || o.RecipientID == req.Caller.ID {
			out = append(out, s.view(ctx, o, names, handles))
		}
	}
	return helper.JSON(map[string]any{"offers": out})
}

// view renders an offer with the workspace name and both parties' handles,
// which is what an inbox shows. names/handles memoize lookups.
func (s *Service) view(ctx context.Context, o models.Offer, names, handles map[string]string) map[string]any {
	b, _ := json.Marshal(o)
	out := map[string]any{}
	_ = json.Unmarshal(b, &out)
	if _, ok := names[o.SpaceID.String()]; !ok {
		var project space.Space
		if s.R.Get(ctx, "spaces", o.SpaceID, &project) == nil {
			names[o.SpaceID.String()] = project.Name
		} else {
			names[o.SpaceID.String()] = ""
		}
	}
	handle := func(id identity.ID) string {
		if h, ok := handles[id.String()]; ok {
			return h
		}
		var person account.Account
		if s.R.Get(ctx, "accounts", id, &person) == nil {
			handles[id.String()] = person.Handle
		} else {
			handles[id.String()] = ""
		}
		return handles[id.String()]
	}
	out["space_name"] = names[o.SpaceID.String()]
	out["sender_handle"] = handle(o.SenderID)
	out["recipient_handle"] = handle(o.RecipientID)
	return out
}
func (s *Service) run(ctx context.Context) {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		var rows []models.Offer
		if e := s.R.List(ctx, "talent_offers", database.Filter{In: map[string][]any{"status": {"funding", "settling", "declining"}}, Limit: 50}, &rows); e == nil {
			for _, o := range rows {
				if e = s.finish(ctx, &o); e != nil && errs.CodeOf(e) != errs.CodeConflict {
					o.Error = e.Error()
					o.UpdatedAt = time.Now().UTC()
					_ = s.R.Update(ctx, "talent_offers", o.ID, &o)
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "talent-ns", Version: "1.0.0", Provides: []string{"service/talent"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := &Service{K: d.Kernel, R: repo.New(d.Kernel)}
		var release func()
		actions := []api.Action{
			helper.Action{Namespace: "talent", Name: "create", Summary: "Fund a collaboration offer", Handler: s.create},
			helper.Action{Namespace: "talent", Name: "respond", Summary: "Accept or decline a funded offer", Handler: s.respond},
			helper.Action{Namespace: "talent", Name: "list_mine", Summary: "Own offers", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) { return s.list(c, r, false) }},
			helper.Action{Namespace: "talent", Name: "list_project", Summary: "Project offers", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) { return s.list(c, r, true) }},
		}
		return module.Instance{
			Service: s,
			Models:  append(schema.Models(), models.Models()...),
			Run:     s.run,
			Actions: append(actions, s.requestActions()...),
			// The partner API: GET /v1/partner/talent-requests on the developer host.
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return errs.New(errs.CodeUnavailable, "host does not support plugin network bindings")
				}
				var err error
				release, err = binder.BindRoutes("talent", s.Register, s.Unregister)
				return err
			},
			Close: func(context.Context) error {
				if release != nil {
					release()
				}
				return nil
			},
		}, nil
	})
}
