package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
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

var deniedNamespaces = map[string]bool{
	"admin": true, "auth": true, "plugins": true, "federation": true, "developer": true,
	"usage": true, "llm": true, "settings": true, "hostaccess": true, "enterprise": true,
}

var deniedActions = map[string]bool{
	"finance.transfer": true, "finance.faucet": true, "finance.wallet_mint": true, "finance.pay_bot": true,
	"finance.pool_create": true, "finance.pool_consume": true, "finance.pool_free": true,
	"spaces.space_list_all": true, "spaces.admin_files": true,
	"spaces.admin_work_log": true, "spaces.admin_terminate_sandbox": true,
	"spaces.admin_sandboxes": true, "spaces.admin_storage": true,
	"spaces.admin_chat_reports": true, "spaces.admin_chat_report_resolve": true,
	"users.accounts_list": true, "users.account_update": true,
	"users.account_password": true, "users.account_delete": true,
	"users.account_create": true,
	"bots.entity_put": true, "bots.entity_delete": true,
	"market.approve": true, "market.deny": true, "market.stats": true,
	"posts.admin_post_reports": true, "posts.admin_post_report_resolve": true,
}

// agentAllows reports whether an agent session may call namespace.action.
func agentAllows(name string) bool {
	name = strings.TrimSpace(name)
	ns, action, ok := strings.Cut(name, ".")
	if !ok || ns == "" || action == "" {
		return false
	}
	if deniedNamespaces[ns] || deniedActions[name] {
		return false
	}
	// Administrative actions of any namespace are the node admin's.
	return !strings.HasPrefix(action, "admin_")
}

// roomNamespaces are the space-bound namespaces a room agent works in.
var roomNamespaces = map[string]bool{"spaces": true, "routines": true, "tools": true, "message": true}

// roomGlobal are the account-wide actions a room agent may also call.
var roomGlobal = map[string]bool{
	"users.search": true, "users.account_get": true, "users.dm_send": true, "users.dm_list": true,
	"market.catalog": true, "market.get": true, "market.recommend": true, "market.list": true,
	"themes.get": true, "talent.list_project": true,
}

// roomDenied are actions of the space-bound namespaces that reach beyond one space.
var roomDenied = map[string]bool{
	"spaces.space_create": true, "spaces.space_list": true, "spaces.space_search": true,
	"spaces.chat_list": true, "spaces.direct_open": true, "spaces.space_delete": true,
}

// roomAllows reports whether a room agent may call namespace.action.
func roomAllows(name string) bool {
	if !agentAllows(name) || roomDenied[name] {
		return false
	}
	ns, _, _ := strings.Cut(name, ".")
	return roomNamespaces[ns] || roomGlobal[name]
}

func (s *session) allows(name string) bool {
	if s.personal {
		return agentAllows(name)
	}
	return roomAllows(name)
}

// catalogEntry is one callable action, as agents search for it.
type catalogEntry struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Summary   string `json:"summary,omitempty"`
}

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
			all = append(all, scored{catalogEntry{Namespace: m.Namespace, Name: m.Name, Summary: m.Summary}, score})
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
