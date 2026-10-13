package tools

import (
	"context"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// OAuth discovery for an MCP server, in the order the MCP authorization
// specification gives: the server names its protected-resource metadata in the
// WWW-Authenticate header of its 401, else it is at a well-known address for the
// server's path, else at the origin's. That metadata names the authorization
// server, whose own metadata sits at one of several well-known addresses
// depending on whether the issuer has a path (RFC 8414, OpenID Connect).

var resourceMetadataParam = regexp.MustCompile(`resource_metadata="([^"]+)"`)

// resourceMetadataURLs lists where a server's protected-resource metadata may
// be, most specific first. challenge is its WWW-Authenticate header, if any.
func resourceMetadataURLs(resource *url.URL, challenge string) []string {
	origin := resource.Scheme + "://" + resource.Host
	var out []string
	if m := resourceMetadataParam.FindStringSubmatch(challenge); m != nil {
		out = append(out, m[1])
	}
	if path := strings.TrimRight(resource.Path, "/"); path != "" {
		out = append(out, origin+"/.well-known/oauth-protected-resource"+path)
	}
	return append(out, origin+"/.well-known/oauth-protected-resource")
}

// authorizationMetadataURLs lists where an issuer's metadata may be. extra are
// addresses to try as well: the MCP server's own, for servers that publish
// their authorization server's metadata themselves.
func authorizationMetadataURLs(issuer string, extra ...string) []string {
	var out []string
	if u, e := url.Parse(issuer); e == nil && u.Host != "" {
		origin := u.Scheme + "://" + u.Host
		if path := strings.TrimRight(u.Path, "/"); path != "" {
			out = append(out,
				origin+"/.well-known/oauth-authorization-server"+path,
				origin+"/.well-known/openid-configuration"+path,
				origin+path+"/.well-known/oauth-authorization-server",
				origin+path+"/.well-known/openid-configuration")
		} else {
			out = append(out,
				origin+"/.well-known/oauth-authorization-server",
				origin+"/.well-known/openid-configuration")
		}
	}
	return append(out, extra...)
}

type oauthDiscovery struct {
	Authorization map[string]any
	// Resource is the identifier the server gives itself, else the address asked for.
	Resource string
	Scopes   []string
}

func (s *Service) discoverOAuth(ctx context.Context, resource *url.URL) (*oauthDiscovery, bool) {
	out := &oauthDiscovery{Resource: resource.String()}
	origin := resource.Scheme + "://" + resource.Host
	// An unauthenticated call is refused with a challenge that says where to look.
	_, header, _ := s.Client.FetchJSON(ctx, resource.String(), nil, http.MethodPost, map[string]any{"jsonrpc": "2.0", "id": 1, "method": "ping"})
	issuer := origin
	for _, target := range resourceMetadataURLs(resource, header.Get("WWW-Authenticate")) {
		meta, _, e := s.Client.FetchJSON(ctx, target, nil, http.MethodGet, nil)
		servers, _ := meta["authorization_servers"].([]any)
		if e != nil || len(servers) == 0 {
			continue
		}
		if first, _ := servers[0].(string); first != "" {
			issuer = first
		}
		if named, _ := meta["resource"].(string); named != "" {
			out.Resource = named
		}
		scopes, _ := meta["scopes_supported"].([]any)
		for _, scope := range scopes {
			if text, _ := scope.(string); text != "" {
				out.Scopes = append(out.Scopes, text)
			}
		}
		break
	}
	extra := authorizationMetadataURLs(origin)
	if path := strings.TrimRight(resource.Path, "/"); path != "" {
		extra = append([]string{origin + "/.well-known/oauth-authorization-server" + path}, extra...)
	}
	for _, target := range authorizationMetadataURLs(issuer, extra...) {
		meta, _, e := s.Client.FetchJSON(ctx, target, nil, http.MethodGet, nil)
		if e != nil {
			continue
		}
		if endpoint, _ := meta["authorization_endpoint"].(string); endpoint != "" {
			out.Authorization = meta
			return out, true
		}
	}
	return nil, false
}
