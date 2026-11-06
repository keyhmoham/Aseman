package apihttp

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
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

// App server access (app_api.go): the user token the gateway hands an app,
// and who an app server's credential acts as.
func (p gatewayBridge) AppUserToken(px *proxy.Proxy, viewer identity.ID) (string, error) {
	var out string
	err := bridge.Invoke(context.Background(), p.k, "spaces", "AppUserToken", []any{px, viewer}, &out)
	return out, err
}
func (p gatewayBridge) AppCaller(ctx context.Context, token string) (*proxy.Access, error) {
	var out *proxy.Access
	err := bridge.Invoke(ctx, p.k, "spaces", "AppCaller", []any{ctx, token}, &out)
	return out, err
}
func (p gatewayBridge) AppAPIURL() string {
	var out string
	_ = bridge.Invoke(context.Background(), p.k, "spaces", "AppAPIURL", []any{}, &out)
	return out
}

// Platform frontends (platform_app.go).
func (p gatewayBridge) PlatformFrontendFor(ctx context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error) {
	var out *models.PlatformFrontend
	err := bridge.Invoke(ctx, p.k, "developer", "PlatformFrontendFor", []any{ctx, ref, viewer}, &out)
	return out, err
}
func (p gatewayBridge) PlatformUserToken(px *proxy.Proxy, viewer identity.ID, platformID string) (string, error) {
	var out string
	err := bridge.Invoke(context.Background(), p.k, "spaces", "PlatformUserToken", []any{px, viewer, platformID}, &out)
	return out, err
}
func (p gatewayBridge) ProxyOpen(ctx context.Context, id, actor identity.ID) (map[string]any, error) {
	var out map[string]any
	err := bridge.Invoke(ctx, p.k, "spaces", "ProxyOpen", []any{ctx, id, actor}, &out)
	return out, err
}

func (p gatewayBridge) WakeFrontend(ctx context.Context, id, publisher identity.ID, wait time.Duration) (proxy.Wake, error) {
	var out proxy.Wake
	err := bridge.Invoke(ctx, p.k, "spaces", "WakeFrontend", []any{ctx, id, publisher, wait}, &out)
	return out, err
}
func (p gatewayBridge) HoldFrontend(ctx context.Context, id identity.ID) error {
	return bridge.Invoke(ctx, p.k, "spaces", "HoldFrontend", []any{ctx, id})
}

func (p gatewayBridge) CanProxy(ctx context.Context, id, actor identity.ID, write bool) error {
	return bridge.Invoke(ctx, p.k, "spaces", "CanProxy", []any{ctx, id, actor, write})
}

// The bridge serves app servers and platform frontends: without these the
// gateway hands apps no user token and answers their API "unavailable".
var (
	_ appAccess         = gatewayBridge{}
	_ platformFrontends = gatewayBridge{}
)
