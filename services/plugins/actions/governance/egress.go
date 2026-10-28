package governance

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"os"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/egress"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Where a project's computer may connect. The computer's filtering proxy
// (cmd/aseman-egress, a sidecar in the computer's network namespace that the
// shell and the browser go through) reads the policy from the node when it
// starts and every half minute after; until it has one, nothing leaves. The
// gate applies the same policy to the URLs in commands before they run.
//
// A process that ignores the proxy settings and opens a raw socket is not
// stopped by the proxy; on Kubernetes, a NetworkPolicy closes that.

// EgressPath is where the proxy reads its policy.
const EgressPath = "/governance/v1/egress"

// defaultEgressMode is a project's mode until its owner picks one.
func defaultEgressMode() string {
	if m := strings.TrimSpace(os.Getenv("ASEMAN_EGRESS_DEFAULT_MODE")); egress.Valid(m) {
		return m
	}
	return egress.AllowAll
}

// Egress is a project's policy as the proxy is given it.
func (s *Service) Egress(ctx context.Context, space string) (egress.Policy, error) {
	id, err := identity.Parse(space)
	if err != nil {
		return egress.Policy{}, errs.InvalidArgument("invalid project id")
	}
	p := egress.Policy{Mode: defaultEgressMode(), Allow: []string{}}
	var row gov.EgressPolicy
	if err := s.R.Get(ctx, "egress_policies", id, &row); err == nil {
		p.Mode, p.Allow = row.Mode, row.Allow
	} else if errs.CodeOf(err) != errs.CodeNotFound {
		return egress.Policy{}, err
	}
	p.Always = alwaysHosts()
	return p, nil
}

// alwaysHosts are the node and the services the computer is served by.
func alwaysHosts() []string {
	var out []string
	for _, v := range []string{"ASEMAN_AGENT_NODE_URL", "ASEMAN_SANDBOX_LLM_URL", "ASEMAN_PUBLIC_URL"} {
		if u, err := url.Parse(strings.TrimSpace(os.Getenv(v))); err == nil && u.Hostname() != "" {
			out = append(out, u.Hostname())
		}
	}
	for _, h := range strings.Split(os.Getenv("ASEMAN_EGRESS_ALWAYS"), ",") {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	return append(out, "aseman", "localhost", "127.0.0.1", "::1")
}

// SetEgress stores a project's policy (its owner or administrators).
func (s *Service) SetEgress(ctx context.Context, caller identity.ID, space, mode string, allow []string) (egress.Policy, error) {
	if !s.canManage(ctx, caller, space) {
		return egress.Policy{}, errNotAllowed
	}
	if !egress.Valid(mode) {
		return egress.Policy{}, errs.InvalidArgument("mode is allow_all, defaults_plus_allowlist, allowlist_only or deny_all")
	}
	clean := []string{}
	for _, h := range allow {
		h = strings.ToLower(strings.TrimSpace(h))
		if h == "" {
			continue
		}
		if !egress.ValidPattern(h) {
			return egress.Policy{}, errs.InvalidArgument("not a host or *.domain: " + h)
		}
		clean = append(clean, h)
	}
	id, err := identity.Parse(space)
	if err != nil {
		return egress.Policy{}, errs.InvalidArgument("invalid project id")
	}
	now := s.now().UTC()
	row := gov.EgressPolicy{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, Mode: mode, Allow: clean, UpdatedBy: caller.String()}
	var old gov.EgressPolicy
	if s.R.Get(ctx, "egress_policies", id, &old) == nil {
		row.CreatedAt = old.CreatedAt
		err = s.R.Update(ctx, "egress_policies", id, &row)
	} else {
		err = s.R.CreateID(ctx, "egress_policies", id, &row)
	}
	if err != nil {
		return egress.Policy{}, err
	}
	s.Event(ctx, "egress.changed", space, caller.String(), mode+" "+strings.Join(clean, ","))
	return s.Egress(ctx, space)
}

// EgressToken is the credential a project's proxy reads its policy with.
func (s *Service) EgressToken(space string) string {
	mac := hmac.New(sha256.New, []byte(s.K.Env()["node_private_key"]))
	mac.Write([]byte("aseman/egress/" + space))
	return hex.EncodeToString(mac.Sum(nil))
}

// egressRefusal refuses a computer command reaching a host the project's
// policy does not allow.
func (s *Service) egressRefusal(ctx context.Context, req gate.Request) string {
	if req.SpaceID == "" || req.URL == "" || !(req.Kind == gate.KindSandbox || computerTools[req.Tool]) {
		return ""
	}
	p, err := s.Egress(ctx, req.SpaceID)
	if err != nil {
		return ""
	}
	if host := hostOf(req.URL); host != "" && !p.AllowsHost(host) {
		return "the project computer may not connect to " + host + " (network policy " + p.Mode + "). Ask the project's owner to allow it."
	}
	return ""
}

// serveEgress answers a proxy's policy request.
func (s *Service) serveEgress(ctx context.Context, req *network.Request) (*network.Response, error) {
	space := req.Query.Get("space")
	token := strings.TrimSpace(strings.TrimPrefix(headerValue(req.Header, "Authorization"), "Bearer "))
	if space == "" || token == "" || !hmac.Equal([]byte(token), []byte(s.EgressToken(space))) {
		return jsonStatus(401, map[string]any{"error": "unauthorized"}), nil
	}
	p, err := s.Egress(ctx, space)
	if err != nil {
		return jsonStatus(400, map[string]any{"error": err.Error()}), nil
	}
	return jsonStatus(200, p), nil
}

func headerValue(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}
