package apihttp

// The address a person reaches the node at, noted for the spaces namespace
// (spaces/public_url.go): a platform's Android app is built with the node's
// public address, and when the node was not told it, the address its
// builder opens Aseman at is the next best. Behind the web app's nginx or
// Caddy that is the forwarded scheme and host; a browser's Origin otherwise.

import (
	"context"
	"net/url"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// publicOriginEvery is how often one person's unchanged origin is noted again.
const publicOriginEvery = time.Hour

type notedOrigin struct {
	origin string
	at     time.Time
}

// requestOrigin is the origin a request reached the node at, or "".
func requestOrigin(req *network.Request) string {
	first := func(v string) string { return strings.TrimSpace(strings.Split(v, ",")[0]) }
	if host := first(signing.Header(req.Header, "X-Forwarded-Host")); host != "" {
		scheme := strings.ToLower(first(signing.Header(req.Header, "X-Forwarded-Proto")))
		if scheme != "https" {
			scheme = "http"
		}
		return scheme + "://" + host + strings.TrimRight(first(signing.Header(req.Header, "X-Forwarded-Prefix")), "/")
	}
	if origin := signing.Header(req.Header, "Origin"); origin != "" && req.Host != "" {
		if u, err := url.Parse(origin); err == nil && strings.EqualFold(u.Hostname(), req.Host) {
			return origin
		}
	}
	return ""
}

// notePublicOrigin hands the spaces namespace the origin [person] reached
// the node at, when it changed or an hour went by.
func (a *API) notePublicOrigin(person identity.ID, req *network.Request) {
	origin := requestOrigin(req)
	if origin == "" || person.IsZero() || a.K == nil {
		return
	}
	if prev, ok := a.publicOrigins.Load(person); ok {
		p := prev.(notedOrigin)
		if p.origin == origin && time.Since(p.at) < publicOriginEvery {
			return
		}
	}
	a.publicOrigins.Store(person, notedOrigin{origin: origin, at: time.Now()})
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := bridge.Invoke(ctx, a.K, "spaces", "NotePublicOrigin", []any{ctx, person, origin}); err != nil && a.Log != nil {
			a.Log.Debug("public origin not noted", "error", err)
		}
	}()
}
