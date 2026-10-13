// Package proxy models a platform gateway tunnel to a port of a space's Modal
// sandbox. tradera creates one when an agent built something (a landing page,
// an HTTP route, a dev server) so users of the space can open it in a webview.
package proxy

import (
	"net/url"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
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

// Keep the time import used even if JSON tags change.
var _ = time.Now
