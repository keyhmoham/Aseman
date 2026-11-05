// Package proxy models a platform gateway tunnel to a port of a space's Modal
// sandbox. aseman creates one when an agent built something (a landing page,
// an HTTP route, a dev server) so users of the space can open it in a webview.
package proxy

import (
	"net/url"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

func (p *Proxy) PreservesPath() bool {
	u, err := url.Parse(p.TargetURL)
	return err == nil && strings.TrimRight(u.Path, "/") == strings.TrimRight(p.GatewayPath(), "/")
}

// Proxy is a gateway tunnel to a sandbox port.
type Proxy struct {
	entity.Entity
	SpaceID identity.ID `db:"space_id" json:"space_id"`
	RoomID  identity.ID `db:"room_id" json:"room_id,omitempty"`
	OwnerID identity.ID `db:"owner_id" json:"owner_id,omitempty"`
	Port    int         `db:"port" json:"port"`
	Title   string      `db:"title" json:"title"`
	// TargetURL is the Modal connect-token URL the gateway proxies to.
	TargetURL string `db:"target_url" json:"-"`
	// Token is the Modal connect-token bearer credential the gateway forwards.
	Token string `db:"token" json:"-"`
	// Path is the relative gateway route, e.g. /v1/proxy/{id}/.
	Path string `db:"path" json:"path,omitempty"`
}

// GatewayPath returns the relative route users open to reach the proxied port.
func (p *Proxy) GatewayPath() string {
	if p.Path != "" {
		return p.Path
	}
	return "/v1/proxy/" + p.ID.String() + "/"
}

// Access is who an app server's call to the node runs as (see
// spaces/app_access.go).
type Access struct {
	// Proxy is the app's preview: its space and room scope the call.
	Proxy *Proxy
	// Payer is the person the call runs as and is billed to.
	Payer *account.Account
	// Via says how the app acts, for usage records: "app <title>" or
	// "app <title> (background)".
	Via string
	// Platform is set when the app serves a sub-platform's person as that
	// platform's frontend: the call runs as (and bills) Payer, the frontend's
	// publisher, for User, and reaches only the agents and apps the app is
	// wired to (Platform.Wiring).
	Platform *models.PlatformFrontend
	// User is the platform's person the app is serving (nil otherwise).
	User *account.Account
}

// Keep the time import used even if JSON tags change.
var _ = time.Now
