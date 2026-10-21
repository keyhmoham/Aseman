package market

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// publishAction implements market.publish.
type publishAction struct{ s *Service }

func (a *publishAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "publish", Summary: "Publish an agent or app to the marketplace"}
}
func (a *publishAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot         string `json:"bot"`
		Type        string `json:"type"` // agent | tool
		Name        string `json:"name,omitempty"`
		Description string `json:"description,omitempty"`
		Price       int64  `json:"price,omitempty"`
		Category    string `json:"category,omitempty"`
		ImageRef    string `json:"image_ref,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	botID, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	itemType := market.ItemType(in.Type)
	if itemType == "" {
		itemType = market.ItemAgent
	}
	l, err := a.s.Publish(ctx, req.Caller.ID, botID, itemType, in.Name, in.Description, in.Price, in.Category, in.ImageRef)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"listing_id": l.ID.String(), "status": l.Status, "ok": true})
}

// unpublishAction implements market.unpublish.
type unpublishAction struct{ s *Service }

func (a *unpublishAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "unpublish", Summary: "Hide a listing from the marketplace"}
}
func (a *unpublishAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Listing string `json:"listing"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Listing)
	if err != nil {
		return nil, errs.InvalidArgument("invalid listing id")
	}
	if err := a.s.Unpublish(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// listAction implements market.list.
type listAction struct{ s *Service }

func (a *listAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "list", Summary: "Browse agents and apps in the marketplace"}
}
func (a *listAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Type     string `json:"type,omitempty"`
		Category string `json:"category,omitempty"`
		Query    string `json:"query,omitempty"`
		Limit    int    `json:"limit,omitempty"`
		Offset   int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	list, err := a.s.List(ctx, in.Type, in.Category, in.Query, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	items := make([]map[string]any, 0, len(list))
	for i := range list {
		item := map[string]any{}
		b, _ := json.Marshal(list[i])
		_ = json.Unmarshal(b, &item)
		item["avatar"] = a.s.AvatarOf(ctx, list[i].BotID)
		items = append(items, item)
	}
	return helper.JSON(map[string]any{"items": items})
}

// getAction implements market.get.
type getAction struct{ s *Service }

func (a *getAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "get", Summary: "Fetch a listing with its bot details"}
}
func (a *getAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Listing string `json:"listing"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Listing)
	if err != nil {
		return nil, errs.InvalidArgument("invalid listing id")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Listing, "market", "get", req); ok {
		return resp, err
	}
	d, err := a.s.DetailFor(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(d)
}

// installAction implements market.install.
type installAction struct{ s *Service }

func (a *installAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "install", Summary: "Install a listing into a workspace"}
}
func (a *installAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Listing string `json:"listing"`
		Space   string `json:"space,omitempty"`
		Room    string `json:"room,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	listingID, err := identity.Parse(in.Listing)
	if err != nil {
		return nil, errs.InvalidArgument("invalid listing id")
	}
	var spaceID, roomID identity.ID
	if in.Space != "" {
		spaceID, err = identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space id")
		}
	}
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	l, err := a.s.Install(ctx, req.Caller.ID, listingID, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"listing_id": l.ID.String(), "bot_id": l.BotID.String(), "installs": l.Installs, "ok": true})
}

// myListingsAction implements market.my_listings.
type myListingsAction struct{ s *Service }

func (a *myListingsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "market", Name: "my_listings", Summary: "List the listings I published"}
}
func (a *myListingsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	list, err := a.s.MyListings(ctx, req.Caller.ID)
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
	return helper.JSON(map[string]any{"items": list[start:end]})
}

// BuildActions assembles the market namespace actions.
func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		&publishAction{s: s}, &unpublishAction{s: s},
		&listAction{s: s}, &getAction{s: s}, &installAction{s: s},
		&myListingsAction{s: s},
	}, catalogActions(s)...)
}
