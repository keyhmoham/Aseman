package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// proxyCreateAction implements spaces.proxy_create: open a gateway tunnel to a
// port of the space's Modal sandbox so users can open what it serves in a webview.
type proxyCreateAction struct{ s *Service }

func (a *proxyCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "proxy_create", Summary: "Create a gateway proxy to a port of the space's sandbox"}
}
func (a *proxyCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space        string `json:"space"`
		Room         string `json:"room,omitempty"`
		Port         int    `json:"port"`
		Title        string `json:"title,omitempty"`
		PreservePath bool   `json:"preserve_path,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spID, roomID, true, "proxy_create"); err != nil {
		return nil, err
	}
	p, err := a.s.proxyCreate(ctx, spID, roomID, req.Caller.ID, in.Port, in.Title, in.PreservePath)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"proxy_id": p.ID.String(), "space_id": p.SpaceID.String(),
		"port": p.Port, "title": p.Title, "url": p.GatewayPath(), "ok": true,
	})
}

// proxyListAction implements spaces.proxy_list.
type proxyListAction struct{ s *Service }

func (a *proxyListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "proxy_list", Summary: "List the gateway proxies of a space"}
}
func (a *proxyListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spID, identity.ID{}, false); err != nil {
		return nil, err
	}
	list, err := a.s.ProxyList(ctx, spID)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		out = append(out, map[string]any{
			"id": p.ID.String(), "port": p.Port, "title": p.Title, "url": p.GatewayPath(),
			"created_at": p.CreatedAt, "kind": proxyKind(&p),
		})
	}
	return helper.JSON(map[string]any{"proxies": out})
}

// proxyGetAction implements spaces.proxy_get.
type proxyGetAction struct{ s *Service }

func (a *proxyGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "proxy_get", Summary: "Get a gateway proxy"}
}
func (a *proxyGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Proxy string `json:"proxy"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Proxy)
	if err != nil {
		return nil, errs.InvalidArgument("invalid proxy id")
	}
	p, err := a.s.ProxyGet(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, p.SpaceID, p.RoomID, false); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"id": p.ID.String(), "space_id": p.SpaceID.String(), "port": p.Port,
		"title": p.Title, "url": p.GatewayPath(),
	})
}

// proxyDeleteAction implements spaces.proxy_delete.
type proxyDeleteAction struct{ s *Service }

func (a *proxyDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "proxy_delete", Summary: "Delete a gateway proxy"}
}
func (a *proxyDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Proxy string `json:"proxy"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Proxy)
	if err != nil {
		return nil, errs.InvalidArgument("invalid proxy id")
	}
	p, err := a.s.ProxyGet(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckResourceManager(helper.WithActor(ctx, req.Caller.ID), a.s.R, p.SpaceID, p.RoomID, p.OwnerID, "proxy_delete"); err != nil {
		return nil, err
	}
	if err := a.s.ProxyDelete(ctx, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
