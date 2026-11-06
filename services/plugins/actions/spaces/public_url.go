package spaces

// The node's public address: where a phone reaches it. A platform's Android
// app is built with it (platform_client.go), so it must be an address people
// actually open Aseman at, never the node's own loopback or the compose
// network's name for it.
//
// In order:
//
//  1. the address asked for (node_url);
//  2. ASEMAN_PUBLIC_URL;
//  3. the node's own URL (config node.url, which ASEMAN_NODE_URL sets — the
//     compose files pass ASEMAN_PUBLIC_URL, or https://API_DOMAIN, in it);
//  4. the address the person building was last seen reaching the node at:
//     the gateway notes the origin of each signed-in person's requests
//     (NotePublicOrigin) — behind the web app's nginx or Caddy, the forwarded
//     host and scheme. It is the person's own: a forwarded host anyone can
//     set, so one person's never decides another's app.
//
// Chosen automatically, an address only a machine itself or its private
// network reaches (localhost, 127.0.0.1, 10.x, a single-label name like
// "aseman") is passed over.

import (
	"context"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/models/kv"
)

// publicOriginKey is where a person's last seen public origin is kept.
const publicOriginKey = "node.public_origin"

// cleanOrigin reduces an http(s) URL to its origin (scheme://host[:port],
// with a path prefix the node may be served under kept), or "".
func cleanOrigin(raw string) string {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return ""
	}
	return strings.ToLower(u.Scheme) + "://" + strings.ToLower(u.Host) + strings.TrimRight(u.Path, "/")
}

// reachableFromPhones reports whether an origin's host is one a phone on the
// internet could reach: not loopback, private, link-local or a bare name.
func reachableFromPhones(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	host := strings.ToLower(u.Hostname())
	if host == "" || host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") ||
		strings.HasSuffix(host, ".internal") || host == "host.docker.internal" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified())
	}
	// A single-label name (aseman, web) is a container's or a LAN's.
	return strings.Contains(host, ".")
}

// publicNodeURL is the address phones reach this node at (see above).
// [person] is who the app is built for (zero: nobody's address is used).
func (s *Service) publicNodeURL(ctx context.Context, person identity.ID, asked string) (string, error) {
	if strings.TrimSpace(asked) != "" {
		origin := cleanOrigin(asked)
		if origin == "" {
			return "", errs.InvalidArgument("node_url must be an http(s) address, e.g. https://aseman.example")
		}
		return origin, nil
	}
	type candidate struct{ from, value string }
	candidates := []candidate{
		{"ASEMAN_PUBLIC_URL", os.Getenv("ASEMAN_PUBLIC_URL")},
		{"the node's URL (node.url / ASEMAN_NODE_URL)", s.NodeURL},
		{"ASEMAN_NODE_URL", os.Getenv("ASEMAN_NODE_URL")},
		{"the address you open Aseman at", s.seenPublicOrigin(ctx, person)},
	}
	var passed []string
	for _, c := range candidates {
		origin := cleanOrigin(c.value)
		if origin == "" {
			continue
		}
		if reachableFromPhones(origin) {
			return origin, nil
		}
		passed = append(passed, c.from+" is "+origin)
	}
	why := "this node does not know its public address"
	if len(passed) > 0 {
		why = strings.Join(passed, ", ") + ": a phone cannot reach that"
	}
	return "", errs.New(errs.CodeUnavailable, why+". Set ASEMAN_PUBLIC_URL (and ASEMAN_NODE_URL) to the address people open Aseman at, "+
		"e.g. https://api.example.com, and restart the node; or open Aseman once from that address so the node learns it; or pass node_url")
}

// seenPublicOrigin is the public origin [person] was last seen at (from
// memory, else as kept).
func (s *Service) seenPublicOrigin(ctx context.Context, person identity.ID) string {
	if person.IsZero() {
		return ""
	}
	s.publicMu.Lock()
	seen := s.publicOrigins[person]
	s.publicMu.Unlock()
	if seen.origin != "" || s.KV == nil {
		return seen.origin
	}
	item, err := s.KV.Get(ctx, kv.ScopeGlobal, identity.ID{}, person, publicOriginKey)
	if err != nil || item == nil {
		return ""
	}
	return cleanOrigin(item.Value)
}

// seenOrigin is the origin a person was last seen at, and when it was kept.
type seenOrigin struct {
	origin string
	saved  time.Time
}

// NotePublicOrigin records the origin [person]'s request reached the node at
// (the gateway calls it), when a phone could reach it too. It is kept at
// most once an hour, and at once when it changes.
func (s *Service) NotePublicOrigin(ctx context.Context, person identity.ID, origin string) error {
	origin = cleanOrigin(origin)
	if person.IsZero() || origin == "" || !reachableFromPhones(origin) {
		return nil
	}
	s.publicMu.Lock()
	if s.publicOrigins == nil {
		s.publicOrigins = map[identity.ID]seenOrigin{}
	}
	prev := s.publicOrigins[person]
	if prev.origin == origin && time.Since(prev.saved) < time.Hour {
		s.publicMu.Unlock()
		return nil
	}
	s.publicOrigins[person] = seenOrigin{origin: origin, saved: time.Now()}
	s.publicMu.Unlock()
	if s.KV == nil {
		return nil
	}
	return s.KV.Set(ctx, kv.ScopeGlobal, identity.ID{}, person, publicOriginKey, origin)
}
