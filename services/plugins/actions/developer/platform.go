package developer

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Namespaces kept off the developer platform door. Everything else that is
// registered (and not named admin_*) is in the collection so a key can drive
// the same product surface as the Aseman client — spaces, bots, tools, desk,
// messenger, finance, themes, market, posts, routines, and the rest — while
// node administration stays on the signed admin console.
var platformDeniedNamespaces = map[string]bool{
	"admin":     true,
	"developer": true, // console management stays session-signed; this HTTP door is separate
}

// platformAllowed reports whether a namespace.action belongs in the developer
// platform collection (callable with a key that has platform access).
func platformAllowed(ns, action string) bool {
	ns, action = strings.TrimSpace(ns), strings.TrimSpace(action)
	if ns == "" || action == "" {
		return false
	}
	if platformDeniedNamespaces[ns] || strings.HasPrefix(action, "admin_") {
		return false
	}
	return true
}

// PlatformCatalog is every non-admin platform action the developer API exposes.
type PlatformCatalog struct {
	Object     string              `json:"object"`
	Base       string              `json:"base"`
	Hint       string              `json:"hint"`
	Namespaces []PlatformNamespace `json:"namespaces"`
}

// PlatformNamespace is one product area in the collection.
type PlatformNamespace struct {
	Name    string           `json:"name"`
	Actions []PlatformAction `json:"actions"`
}

// PlatformAction is one callable unit.
type PlatformAction struct {
	Name    string `json:"name"`
	Summary string `json:"summary,omitempty"`
	Path    string `json:"path"`
}

// ActorFor returns who a platform call acts as: the person who created the key.
// Team organization keys still act as that person (their memberships and
// wallets), never as the organization itself.
func (s *Service) ActorFor(p *Principal) (identity.ID, string, error) {
	if p == nil || p.Key.CreatedBy.IsZero() {
		return identity.ID{}, "", &AuthError{403, "permission_error", "platform_actor", "This key has no person behind it."}
	}
	handle := s.handleOf(context.Background(), p.Key.CreatedBy)
	if handle == "" {
		return identity.ID{}, "", &AuthError{403, "permission_error", "platform_actor", "This key's owner no longer has an account."}
	}
	return p.Key.CreatedBy, handle, nil
}

// PlatformCatalog builds the live collection from registered actions.
func (s *Service) PlatformCatalog(ctx context.Context) PlatformCatalog {
	router := s.K.Actions()
	namespaces := router.Namespaces()
	sort.Strings(namespaces)
	out := PlatformCatalog{
		Object: "list",
		Base:   "/v1/platform",
		Hint:   "POST /v1/platform/{namespace}/{action} with Authorization: Bearer dk_live_… and a JSON body. Acts as the person who created the key. Node administration is not included.",
	}
	for _, ns := range namespaces {
		if platformDeniedNamespaces[ns] {
			continue
		}
		metas := router.List(ns)
		sort.Slice(metas, func(i, j int) bool { return metas[i].Name < metas[j].Name })
		group := PlatformNamespace{Name: ns}
		for _, m := range metas {
			if !platformAllowed(ns, m.Name) {
				continue
			}
			group.Actions = append(group.Actions, PlatformAction{
				Name: m.Name, Summary: m.Summary,
				Path: "/v1/platform/" + ns + "/" + m.Name,
			})
		}
		if len(group.Actions) > 0 {
			out.Namespaces = append(out.Namespaces, group)
		}
	}
	return out
}

func (s *Service) apiPlatform() []route {
	get := func(p string, h network.Handler) route { return route{network.MethodGet, apiPrefix + p, h} }
	post := func(p string, h network.Handler) route { return route{network.MethodPost, apiPrefix + p, h} }
	return []route{
		get("/platform", s.resource("platform", LevelRead, "platform", s.apiPlatformCatalog)),
		post("/platform/{namespace}/{action}", s.resource("platform", LevelWrite, "platform", s.apiPlatformCall)),
	}
}

func (s *Service) apiPlatformCatalog(ctx context.Context, _ *Principal, _ *network.Request) (any, int, error) {
	return s.PlatformCatalog(ctx), http.StatusOK, nil
}

func (s *Service) apiPlatformCall(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
	ns, action := param(req, "namespace"), param(req, "action")
	if !platformAllowed(ns, action) {
		return nil, 0, &AuthError{404, "invalid_request_error", "not_found", "No such platform action. Node administration and the developer console are not on this door."}
	}
	actor, handle, err := s.ActorFor(p)
	if err != nil {
		return nil, 0, err
	}
	if s.K.Actions() == nil {
		return nil, 0, errs.New(errs.CodeUnavailable, "The platform is unavailable right now.")
	}
	platformID := ""
	if form, _ := s.PlatformOfOrg(ctx, p.Org); form != nil {
		platformID = form.ID.String()
		ctx = helper.WithPlatform(ctx, platformID)
	}
	ar := &api.ActionRequest{
		Caller: api.Caller{ID: actor, Kind: "user"},
		Origin: s.K.NodeID(),
		Body:   req.Body,
		Meta: map[string]any{
			"handle": handle, "developer_key": p.Key.ID.String(), "developer_org": p.Org.String(),
			"platform_id": platformID,
		},
	}
	resp, err := s.K.Actions().Dispatch(ctx, ns, action, ar)
	if err != nil {
		return nil, 0, err
	}
	if resp == nil {
		return map[string]any{"ok": true}, http.StatusOK, nil
	}
	status := resp.Status
	if status == 0 {
		status = http.StatusOK
	}
	var body any
	if len(resp.Body) == 0 {
		body = map[string]any{"ok": true}
	} else if json.Unmarshal(resp.Body, &body) != nil {
		body = map[string]any{"raw": string(resp.Body)}
	}
	return body, status, nil
}
