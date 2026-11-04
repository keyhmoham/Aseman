package harness

import (
	"context"
	_ "embed"
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/agentpolicy"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// What an agent may call through the gateway.
//
// An agent works through the same action API people use: every action the
// node routes, dispatched as the turn's account — the agent's in a space, the
// person's in their own assistant chat — so each action's own authorization
// decides, and the governance gate decides and records every call before it
// runs (gateway.go). On top of that, the gateway never serves an agent:
//   - node administration, authentication and identity, the plugin host,
//     federation and the developer surface;
//   - moving money (transfers, minting, pools, paying bots): reading a wallet
//     is fine, spending from it is the person's;
//   - the model providers and their keys (models are reached only through
//     the metered /llm endpoint).
// A room agent additionally acts only inside the space of its turn: it may
// call the space-bound namespaces (spaces, routines, tools, message) — never
// to create or list other spaces — and a few account-wide lookups; the
// person's own surfaces (posts, wallet, themes, following, agents of their
// account) are the person's assistant's, not a space agent's.

// agentAllows reports whether an agent session in the account scope may call
// namespace.action; roomAllows, in a space.
func agentAllows(name string) bool { return agentpolicy.Allows(agentpolicy.Account, name) }
func roomAllows(name string) bool  { return agentpolicy.Allows(agentpolicy.Space, name) }

func (s *session) allows(name string) bool {
	if s.personal {
		return agentAllows(name)
	}
	return roomAllows(name)
}

// catalogEntry is one callable action, as agents search for it: with the
// fields its body takes, when the source says (action_schemas.json).
type catalogEntry struct {
	Namespace string         `json:"namespace"`
	Name      string         `json:"name"`
	Summary   string         `json:"summary,omitempty"`
	Input     map[string]any `json:"input,omitempty"`
}

// actionSchemas are the actions' input schemas, read from their source by
// cmd/gen-action-schemas (TestActionSchemasAreCurrent keeps them current).
//
//go:generate go run ../../../../cmd/gen-action-schemas -module ../../../.. -out action_schemas.json
//go:embed action_schemas.json
var actionSchemasJSON []byte

var actionSchemas = sync.OnceValue(func() map[string]map[string]any {
	out := map[string]map[string]any{}
	_ = json.Unmarshal(actionSchemasJSON, &out)
	return out
})

// catalog lists the actions a session may call, filtered by words and namespace.
func catalog(router api.ActionRouter, allows func(string) bool, query, namespace string, limit int) []catalogEntry {
	if router == nil {
		return nil
	}
	words := strings.Fields(strings.ToLower(query))
	type scored struct {
		e     catalogEntry
		score int
	}
	var all []scored
	for _, ns := range router.Namespaces() {
		if namespace != "" && ns != namespace {
			continue
		}
		for _, m := range router.List(ns) {
			if !allows(m.Namespace + "." + m.Name) {
				continue
			}
			hay := strings.ToLower(m.Namespace + " " + strings.ReplaceAll(m.Name, "_", " ") + " " + m.Summary)
			score := 0
			for _, w := range words {
				if strings.Contains(hay, w) {
					score++
				}
			}
			if len(words) > 0 && score == 0 {
				continue
			}
			all = append(all, scored{catalogEntry{Namespace: m.Namespace, Name: m.Name, Summary: m.Summary, Input: actionSchemas()[m.Namespace+"."+m.Name]}, score})
		}
	}
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].score != all[j].score {
			return all[i].score > all[j].score
		}
		return all[i].e.Namespace+"."+all[i].e.Name < all[j].e.Namespace+"."+all[j].e.Name
	})
	if limit <= 0 || limit > 80 {
		limit = 40
	}
	if len(all) > limit {
		all = all[:limit]
	}
	out := make([]catalogEntry, len(all))
	for i, sc := range all {
		out[i] = sc.e
	}
	return out
}

// serveCatalog: GET {gateway}/catalog?q=&namespace= → {actions}.
func (a *Adapter) serveCatalog(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return errorResponse(errs.Unauthenticated("invalid or expired agent turn token")), nil
	}
	q := url.Values{}
	if req.Query != nil {
		q = req.Query
	}
	var router api.ActionRouter
	if a.k != nil {
		router = a.k.Actions()
	}
	return jsonResponse(http.StatusOK, map[string]any{"actions": catalog(router, s.allows, q.Get("q"), q.Get("namespace"), 40)}), nil
}

// --- the project timeline ------------------------------------------------------------

func (a *Adapter) timelineSession(req *network.Request) (*session, *network.Response) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return nil, errorResponse(errs.Unauthenticated("invalid or expired agent turn token"))
	}
	if s.personal || s.spaceID == "" {
		return nil, errorResponse(errs.InvalidArgument("the timeline is a project's: this conversation is not in one"))
	}
	if noMemory(s) {
		// A request processed freshly reads nothing of the project's past.
		return nil, errorResponse(errs.Permission("this request is processed without the project's history"))
	}
	if a.platform == nil {
		return nil, jsonResponse(http.StatusServiceUnavailable, map[string]any{"error": "the timeline is not available"})
	}
	return s, nil
}

// serveTimelineSearch: POST {gateway}/timeline/search {query, kinds, since, until, limit} → {items}.
func (a *Adapter) serveTimelineSearch(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, resp := a.timelineSession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	out, err := a.platform.TimelineSearch(scoped{Context: ctx, values: s.base}, s.spaceID, req.Body)
	if err != nil {
		return errorResponse(err), nil
	}
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: out}, nil
}

// serveTimelineEntry: POST {gateway}/timeline/entry {id} → {entry, before, after}.
func (a *Adapter) serveTimelineEntry(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, resp := a.timelineSession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	var in struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil || strings.TrimSpace(in.ID) == "" {
		return errorResponse(errs.InvalidArgument("timeline entry id required")), nil
	}
	out, err := a.platform.TimelineEntry(scoped{Context: ctx, values: s.base}, s.spaceID, in.ID)
	if err != nil {
		return errorResponse(err), nil
	}
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: out}, nil
}
