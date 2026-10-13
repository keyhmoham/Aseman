package apihttp

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

type gatewayBridge struct{ k api.Kernel }

func (p gatewayBridge) Authenticate(ctx context.Context, token string) (*account.Account, error) {
	if host, ok := p.k.(interface {
		Authenticate(context.Context, string, bool) (*account.Account, error)
	}); ok {
		return host.Authenticate(ctx, token, false)
	}
	return helper.SessionAccount(ctx, repo.New(p.k), token)
}
func (p gatewayBridge) GetFile(ctx context.Context, id identity.ID) (*filedata.File, error) {
	var out *filedata.File
	err := bridge.Invoke(ctx, p.k, "spaces", "GetFile", []any{ctx, id}, &out)
	return out, err
}
func (p gatewayBridge) CanReadFile(ctx context.Context, id, actor identity.ID) error {
	return bridge.Invoke(ctx, p.k, "spaces", "CanReadFile", []any{ctx, id, actor})
}
func (p gatewayBridge) ReadFileBytes(ctx context.Context, file *filedata.File) ([]byte, error) {
	var out []byte
	err := bridge.Invoke(ctx, p.k, "spaces", "ReadFileBytes", []any{ctx, file}, &out)
	return out, err
}
func (p gatewayBridge) ProxyGet(ctx context.Context, id identity.ID) (*proxy.Proxy, error) {
	var out *proxy.Proxy
	err := bridge.Invoke(ctx, p.k, "spaces", "ProxyGet", []any{ctx, id}, &out)
	return out, err
}
func (p gatewayBridge) SpaceMembership(ctx context.Context, id, actor identity.ID) (*membership.Membership, error) {
	var out *membership.Membership
	err := bridge.Invoke(ctx, p.k, "spaces", "SpaceMembership", []any{ctx, id, actor}, &out)
	return out, err
}

// NewHost constructs and wires the protocol gateway's bridge facades.
func NewHost(k Host, log *logger.Logger) *API {
	provider := gatewayBridge{k: k}
	gateway := New(k, provider, log)
	gateway.Spaces = provider
	return gateway
}

func (p gatewayBridge) CanProxy(ctx context.Context, id, actor identity.ID, write bool) error {
	return bridge.Invoke(ctx, p.k, "spaces", "CanProxy", []any{ctx, id, actor, write})
}
