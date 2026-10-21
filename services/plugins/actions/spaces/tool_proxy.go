package spaces

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// ToolProxyTarget is where a tool installed in a space's sandbox answers,
// as the gateway proxy that fronts it knows it.
type ToolProxyTarget struct {
	ProxyID   string `json:"proxy_id"`
	TargetURL string `json:"target_url"`
	Token     string `json:"token,omitempty"`
	Path      string `json:"path"`
}

// EnsureToolProxy is the gateway proxy a tool installed into the space's
// sandbox is reached through: one per tool account and port. It starts the
// sandbox when it sleeps and refreshes the tunnel on every call, since a
// recreated sandbox answers on a new address. Unlike a preview it posts
// nothing into a room and does not hold the sandbox awake.
func (s *Service) EnsureToolProxy(ctx context.Context, spaceID, owner identity.ID, port int, title string) (*ToolProxyTarget, error) {
	if port <= 0 || port > 65535 {
		return nil, errs.InvalidArgument("port must be in 1..65535")
	}
	rec, err := s.SandboxStart(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	tv, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(tunnelVM)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "sandbox provider does not support proxying")
	}
	targetURL, token, err := tv.CreateTunnel(ctx, rec.VMID, port)
	if err != nil {
		return nil, err
	}
	s.touch(spaceID)
	list, err := s.ProxyList(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	for i := range list {
		p := &list[i]
		if p.OwnerID != owner || p.Port != port {
			continue
		}
		if p.TargetURL != targetURL || p.Token != token {
			p.TargetURL, p.Token, p.UpdatedAt = targetURL, token, now
			if err := s.saveProxy(ctx, p, false); err != nil {
				return nil, err
			}
		}
		return &ToolProxyTarget{ProxyID: p.ID.String(), TargetURL: p.TargetURL, Token: p.Token, Path: p.GatewayPath()}, nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	p := &proxy.Proxy{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, OwnerID: owner, Port: port, Title: title,
		TargetURL: targetURL, Token: token, Path: "/v1/proxy/" + id.String() + "/",
	}
	if err := s.saveProxy(ctx, p, true); err != nil {
		return nil, err
	}
	s.L.Info("tool proxy created", "space", spaceID.String(), "proxy", id.String(), "port", port)
	return &ToolProxyTarget{ProxyID: id.String(), TargetURL: targetURL, Token: token, Path: p.GatewayPath()}, nil
}

// SandboxSidecar runs a tool's docker image inside the space sandbox's network
// namespace (see vmm.SidecarRunner), starting the sandbox first.
func (s *Service) SandboxSidecar(ctx context.Context, spaceID identity.ID, name, image string, env map[string]string) error {
	rec, err := s.SandboxStart(ctx, spaceID)
	if err != nil {
		return err
	}
	runner, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(vmm.SidecarRunner)
	if !ok {
		return errs.New(errs.CodeUnavailable, "this node's sandboxes cannot run a docker tool backend ("+string(rec.VMType)+")")
	}
	return runner.EnsureSidecar(ctx, rec.VMID, name, image, env)
}

// installTool installs a tool whose backend runs in the space's sandbox as
// soon as it is added, in the background, so its first user does not wait
// for it. A failure is logged: the first call installs it again.
func (s *Service) installTool(ctx context.Context, spaceID, botID identity.ID) {
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil || rec.VMType != bot.VMTypeInstalled {
		return
	}
	go func() {
		bg, cancel := context.WithTimeout(helper.WithInternalAccess(context.WithoutCancel(ctx)), 5*time.Minute)
		defer cancel()
		if err := bridge.Invoke(bg, s.K, "tools", "Install", []any{bg, spaceID.String(), botID.String()}); err != nil {
			s.L.Warn("install tool", "space", spaceID.String(), "bot", botID.String(), "error", err)
		}
	}()
}
