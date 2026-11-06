package enterprise

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// SCIM 2.0 (RFC 7643/7644) for a directory (Okta, Entra ID, OneLogin,
// JumpCloud): Users and Groups at SCIMPrefix, with the bearer token an
// administrator generates. People it creates sign in through single sign-on;
// SCIM never creates a password anyone knows.
const SCIMPrefix = "/scim/v2"

const (
	schemaUser  = "urn:ietf:params:scim:schemas:core:2.0:User"
	schemaGroup = "urn:ietf:params:scim:schemas:core:2.0:Group"
	schemaList  = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
	schemaError = "urn:ietf:params:scim:api:messages:2.0:Error"
	schemaPatch = "urn:ietf:params:scim:api:messages:2.0:PatchOp"
)

func hashToken(t string) string {
	h := sha256.Sum256([]byte(strings.TrimSpace(t)))
	return hex.EncodeToString(h[:])
}

// NewSCIMToken replaces the directory's token and returns it, once.
func (s *Service) NewSCIMToken(ctx context.Context) (string, error) {
	st, exists := s.settings(ctx)
	token := "scim_" + random(32)
	st.SCIMTokenHash = hashToken(token)
	return token, s.saveSettings(ctx, st, exists)
}

func scimReply(status int, v any) *network.Response {
	raw, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/scim+json"}, Body: raw}
}

func scimError(status int, detail string) *network.Response {
	return scimReply(status, map[string]any{"schemas": []string{schemaError}, "status": strconv.Itoa(status), "detail": detail})
}

func (s *Service) scimAuthorized(ctx context.Context, req *network.Request) bool {
	st, ok := s.settings(ctx)
	if !ok || st.SCIMTokenHash == "" {
		return false
	}
	raw := strings.TrimSpace(strings.TrimPrefix(headerOf(req.Header, "Authorization"), "Bearer "))
	return raw != "" && subtle.ConstantTimeCompare([]byte(hashToken(raw)), []byte(st.SCIMTokenHash)) == 1
}

func headerOf(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func routeID(req *network.Request) string {
	params := map[string]string{}
	_ = json.Unmarshal([]byte(headerOf(req.Header, "x-route-params")), &params)
	return params["id"]
}

// scimHandler wraps a SCIM endpoint with its authorization.
func (s *Service) scimHandler(h func(context.Context, *network.Request) *network.Response) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		if !s.scimAuthorized(ctx, req) {
			return scimError(http.StatusUnauthorized, "invalid SCIM token"), nil
		}
		return h(ctx, req), nil
	}
}

// ── users ───────────────────────────────────────────────────────────────────

type scimUser struct {
	Schemas    []string `json:"schemas"`
	ID         string   `json:"id,omitempty"`
	ExternalID string   `json:"externalId,omitempty"`
	UserName   string   `json:"userName"`
	Name       *struct {
		GivenName  string `json:"givenName,omitempty"`
		FamilyName string `json:"familyName,omitempty"`
	} `json:"name,omitempty"`
	Emails []struct {
		Value   string `json:"value"`
		Primary bool   `json:"primary,omitempty"`
	} `json:"emails,omitempty"`
	Active *bool `json:"active,omitempty"`
}

func (u scimUser) email() string {
	for _, e := range u.Emails {
		if e.Primary {
			return e.Value
		}
	}
	if len(u.Emails) > 0 {
		return u.Emails[0].Value
	}
	if strings.Contains(u.UserName, "@") {
		return u.UserName
	}
	return ""
}

func (s *Service) userResource(p *em.Person) map[string]any {
	groups := []map[string]string{}
	var rows []em.Group
	_ = s.R.List(context.Background(), "directory_groups", database.Filter{Limit: 500}, &rows)
	for _, g := range rows {
		if containsExact(g.Members, p.ID.String()) {
			groups = append(groups, map[string]string{"value": g.ID.String(), "display": g.DisplayName})
		}
	}
	return map[string]any{"schemas": []string{schemaUser}, "id": p.ID.String(), "externalId": p.ExternalID, "userName": p.UserName,
		"name": map[string]string{"givenName": p.GivenName, "familyName": p.FamilyName}, "active": p.Active,
		"emails": []map[string]any{{"value": p.Email, "primary": true}}, "groups": groups,
		"meta": map[string]string{"resourceType": "User", "created": p.CreatedAt.Format(time.RFC3339), "lastModified": p.UpdatedAt.Format(time.RFC3339),
			"location": publicURL() + SCIMPrefix + "/Users/" + p.ID.String()}}
}

var filterRE = regexp.MustCompile(`^\s*(\w+)\s+eq\s+"([^"]*)"\s*$`)

func (s *Service) listUsers(ctx context.Context, req *network.Request) *network.Response {
	f := database.Filter{OrderBy: "created_at", Asc: true, Limit: 1000}
	if m := filterRE.FindStringSubmatch(req.Query.Get("filter")); m != nil {
		field := map[string]string{"userName": "user_name", "externalId": "external_id"}[m[1]]
		if field == "" {
			return scimError(http.StatusBadRequest, "unsupported filter")
		}
		f.Equal = map[string]any{field: m[2]}
	}
	var rows []em.Person
	if err := s.R.List(ctx, "directory_people", f, &rows); err != nil {
		return scimError(http.StatusInternalServerError, err.Error())
	}
	return s.page(req, len(rows), func(i int) any { return s.userResource(&rows[i]) })
}

func (s *Service) page(req *network.Request, total int, item func(int) any) *network.Response {
	start, _ := strconv.Atoi(req.Query.Get("startIndex"))
	if start < 1 {
		start = 1
	}
	count, err := strconv.Atoi(req.Query.Get("count"))
	if err != nil || count < 0 {
		count = 100
	}
	out := []any{}
	for i := start - 1; i < total && len(out) < count; i++ {
		out = append(out, item(i))
	}
	return scimReply(http.StatusOK, map[string]any{"schemas": []string{schemaList}, "totalResults": total, "startIndex": start,
		"itemsPerPage": len(out), "Resources": out})
}

func (s *Service) getUser(ctx context.Context, req *network.Request) *network.Response {
	p, err := s.person(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "user not found")
	}
	return scimReply(http.StatusOK, s.userResource(p))
}

func (s *Service) person(ctx context.Context, id string) (*em.Person, error) {
	pid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.NotFound("user")
	}
	var p em.Person
	if err := s.R.Get(ctx, "directory_people", pid, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

var handleClean = regexp.MustCompile(`[^a-z0-9_]+`)

// createUser provisions a person: an Aseman account (or the existing one with
// that email), active, signing in through SSO.
func (s *Service) createUser(ctx context.Context, req *network.Request) *network.Response {
	var in scimUser
	if err := json.Unmarshal(req.Body, &in); err != nil || in.UserName == "" {
		return scimError(http.StatusBadRequest, "userName is required")
	}
	email := in.email()
	if email == "" {
		return scimError(http.StatusBadRequest, "an email is required")
	}
	var existing []em.Person
	_ = s.R.List(ctx, "directory_people", database.Filter{Equal: map[string]any{"user_name": in.UserName}, Limit: 1}, &existing)
	if len(existing) > 0 {
		return scimError(http.StatusConflict, "userName already exists")
	}
	// SCIM lives on main Aseman; never pick a platform account that
	// happens to share the same email.
	var acc *account.Account
	if found, err := helper.FindAccountByEmail(ctx, s.R, email, ""); err == nil {
		acc = found
	} else {
		base := strings.Trim(handleClean.ReplaceAllString(strings.ToLower(strings.Split(email, "@")[0]), "_"), "_")
		if len(base) < 3 {
			base = "user_" + base
		}
		var err error
		for i := 0; i < 20; i++ {
			handle := base
			if i > 0 {
				handle = base + strconv.Itoa(i+1)
			}
			if acc, err = s.Auth.CreateManagedAccount(ctx, handle, email, random(24)); err == nil {
				break
			}
			if errs.CodeOf(err) != errs.CodeAlreadyExists && errs.CodeOf(err) != errs.CodeConflict {
				return scimError(http.StatusBadRequest, err.Error())
			}
		}
		if acc == nil {
			return scimError(http.StatusConflict, "no free handle for "+base)
		}
	}
	now := s.now().UTC()
	p := &em.Person{Entity: entity.Entity{ID: acc.ID, CreatedAt: now, UpdatedAt: now}, ExternalID: in.ExternalID, UserName: in.UserName,
		Email: email, Active: in.Active == nil || *in.Active, Groups: []string{}}
	if in.Name != nil {
		p.GivenName, p.FamilyName = in.Name.GivenName, in.Name.FamilyName
	}
	if err := s.R.CreateID(ctx, "directory_people", p.ID, p); err != nil {
		return scimError(http.StatusInternalServerError, err.Error())
	}
	if !p.Active {
		s.setActive(ctx, p, false)
	} else {
		s.joinOrganization(ctx, acc.ID, email)
	}
	return scimReply(http.StatusCreated, s.userResource(p))
}

func (s *Service) replaceUser(ctx context.Context, req *network.Request) *network.Response {
	p, err := s.person(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "user not found")
	}
	var in scimUser
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return scimError(http.StatusBadRequest, "invalid user")
	}
	if in.UserName != "" {
		p.UserName = in.UserName
	}
	if in.ExternalID != "" {
		p.ExternalID = in.ExternalID
	}
	if e := in.email(); e != "" {
		p.Email = e
	}
	if in.Name != nil {
		p.GivenName, p.FamilyName = in.Name.GivenName, in.Name.FamilyName
	}
	if in.Active != nil && *in.Active != p.Active {
		s.setActive(ctx, p, *in.Active)
	}
	p.UpdatedAt = s.now().UTC()
	_ = s.R.Update(ctx, "directory_people", p.ID, p)
	return scimReply(http.StatusOK, s.userResource(p))
}

type patchOp struct {
	Op    string          `json:"op"`
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

func (s *Service) patchUser(ctx context.Context, req *network.Request) *network.Response {
	p, err := s.person(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "user not found")
	}
	var in struct {
		Operations []patchOp `json:"Operations"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return scimError(http.StatusBadRequest, "invalid patch")
	}
	for _, op := range in.Operations {
		values := map[string]json.RawMessage{}
		if op.Path != "" {
			values[op.Path] = op.Value
		} else {
			_ = json.Unmarshal(op.Value, &values)
		}
		for path, raw := range values {
			switch strings.ToLower(path) {
			case "active":
				var v any
				_ = json.Unmarshal(raw, &v)
				active := v == true || v == "true" || v == "True"
				if active != p.Active {
					s.setActive(ctx, p, active)
				}
			case "username":
				_ = json.Unmarshal(raw, &p.UserName)
			case "externalid":
				_ = json.Unmarshal(raw, &p.ExternalID)
			case "name.givenname":
				_ = json.Unmarshal(raw, &p.GivenName)
			case "name.familyname":
				_ = json.Unmarshal(raw, &p.FamilyName)
			}
		}
	}
	p.UpdatedAt = s.now().UTC()
	_ = s.R.Update(ctx, "directory_people", p.ID, p)
	return scimReply(http.StatusOK, s.userResource(p))
}

func (s *Service) deleteUser(ctx context.Context, req *network.Request) *network.Response {
	p, err := s.person(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "user not found")
	}
	if p.Active {
		s.setActive(ctx, p, false)
	}
	_ = s.R.Delete(ctx, "directory_people", p.ID)
	return &network.Response{Status: http.StatusNoContent}
}

// setActive deprovisions a person the directory deactivated, or reactivates
// one it had deactivated (never one an administrator disabled).
func (s *Service) setActive(ctx context.Context, p *em.Person, active bool) {
	p.Active = active
	if !active {
		if done, err := s.Deprovision(ctx, p.ID); err != nil {
			s.L.Warn("deprovisioning failed", "account", p.ID.String(), "error", err)
		} else {
			s.L.Info("deprovisioned", "account", p.ID.String(), "done", strings.Join(done, "; "))
		}
		p.DisabledByDirectory = true
		return
	}
	if p.DisabledByDirectory && s.Auth != nil {
		if _, err := s.Auth.SetAccess(ctx, p.ID, account.StatusActive, ""); err == nil {
			p.DisabledByDirectory = false
		}
	}
}

// ── groups ──────────────────────────────────────────────────────────────────

func (s *Service) groupResource(g *em.Group) map[string]any {
	members := []map[string]string{}
	for _, m := range g.Members {
		members = append(members, map[string]string{"value": m})
	}
	return map[string]any{"schemas": []string{schemaGroup}, "id": g.ID.String(), "externalId": g.ExternalID, "displayName": g.DisplayName,
		"members": members, "meta": map[string]string{"resourceType": "Group", "created": g.CreatedAt.Format(time.RFC3339),
			"lastModified": g.UpdatedAt.Format(time.RFC3339), "location": publicURL() + SCIMPrefix + "/Groups/" + g.ID.String()}}
}

func (s *Service) listGroups(ctx context.Context, req *network.Request) *network.Response {
	f := database.Filter{OrderBy: "created_at", Asc: true, Limit: 1000}
	if m := filterRE.FindStringSubmatch(req.Query.Get("filter")); m != nil {
		field := map[string]string{"displayName": "display_name", "externalId": "external_id"}[m[1]]
		if field == "" {
			return scimError(http.StatusBadRequest, "unsupported filter")
		}
		f.Equal = map[string]any{field: m[2]}
	}
	var rows []em.Group
	if err := s.R.List(ctx, "directory_groups", f, &rows); err != nil {
		return scimError(http.StatusInternalServerError, err.Error())
	}
	return s.page(req, len(rows), func(i int) any { return s.groupResource(&rows[i]) })
}

func (s *Service) group(ctx context.Context, id string) (*em.Group, error) {
	gid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.NotFound("group")
	}
	var g em.Group
	if err := s.R.Get(ctx, "directory_groups", gid, &g); err != nil {
		return nil, err
	}
	return &g, nil
}

type scimGroup struct {
	DisplayName string `json:"displayName"`
	ExternalID  string `json:"externalId"`
	Members     []struct {
		Value string `json:"value"`
	} `json:"members"`
}

func (s *Service) createGroup(ctx context.Context, req *network.Request) *network.Response {
	var in scimGroup
	if err := json.Unmarshal(req.Body, &in); err != nil || in.DisplayName == "" {
		return scimError(http.StatusBadRequest, "displayName is required")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return scimError(http.StatusInternalServerError, err.Error())
	}
	now := s.now().UTC()
	g := &em.Group{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, DisplayName: in.DisplayName, ExternalID: in.ExternalID, Members: []string{}}
	for _, m := range in.Members {
		g.Members = append(g.Members, m.Value)
	}
	if err := s.R.CreateID(ctx, "directory_groups", id, g); err != nil {
		return scimError(http.StatusInternalServerError, err.Error())
	}
	s.syncGroups(ctx, g.Members)
	return scimReply(http.StatusCreated, s.groupResource(g))
}

func (s *Service) getGroup(ctx context.Context, req *network.Request) *network.Response {
	g, err := s.group(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "group not found")
	}
	return scimReply(http.StatusOK, s.groupResource(g))
}

func (s *Service) replaceGroup(ctx context.Context, req *network.Request) *network.Response {
	g, err := s.group(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "group not found")
	}
	var in scimGroup
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return scimError(http.StatusBadRequest, "invalid group")
	}
	before := g.Members
	if in.DisplayName != "" {
		g.DisplayName = in.DisplayName
	}
	g.Members = []string{}
	for _, m := range in.Members {
		g.Members = append(g.Members, m.Value)
	}
	g.UpdatedAt = s.now().UTC()
	_ = s.R.Update(ctx, "directory_groups", g.ID, g)
	s.syncGroups(ctx, append(before, g.Members...))
	return scimReply(http.StatusOK, s.groupResource(g))
}

var memberFilter = regexp.MustCompile(`members\[value eq "([^"]+)"\]`)

func (s *Service) patchGroup(ctx context.Context, req *network.Request) *network.Response {
	g, err := s.group(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "group not found")
	}
	var in struct {
		Operations []patchOp `json:"Operations"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return scimError(http.StatusBadRequest, "invalid patch")
	}
	touched := append([]string{}, g.Members...)
	for _, op := range in.Operations {
		kind := strings.ToLower(op.Op)
		switch {
		case strings.EqualFold(op.Path, "displayName"):
			_ = json.Unmarshal(op.Value, &g.DisplayName)
		case strings.EqualFold(op.Path, "members") || (op.Path == "" && kind == "add"):
			var members []struct {
				Value string `json:"value"`
			}
			if op.Path == "" {
				var wrapper struct {
					Members []struct {
						Value string `json:"value"`
					} `json:"members"`
				}
				_ = json.Unmarshal(op.Value, &wrapper)
				members = wrapper.Members
			} else {
				_ = json.Unmarshal(op.Value, &members)
			}
			if kind == "replace" {
				g.Members = []string{}
			}
			for _, m := range members {
				if kind == "remove" {
					g.Members = without(g.Members, m.Value)
				} else if !containsExact(g.Members, m.Value) {
					g.Members = append(g.Members, m.Value)
				}
				touched = append(touched, m.Value)
			}
		case memberFilter.MatchString(op.Path) && kind == "remove":
			id := memberFilter.FindStringSubmatch(op.Path)[1]
			g.Members = without(g.Members, id)
			touched = append(touched, id)
		}
	}
	g.UpdatedAt = s.now().UTC()
	_ = s.R.Update(ctx, "directory_groups", g.ID, g)
	s.syncGroups(ctx, touched)
	return scimReply(http.StatusOK, s.groupResource(g))
}

func (s *Service) deleteGroup(ctx context.Context, req *network.Request) *network.Response {
	g, err := s.group(ctx, routeID(req))
	if err != nil {
		return scimError(http.StatusNotFound, "group not found")
	}
	_ = s.R.Delete(ctx, "directory_groups", g.ID)
	s.syncGroups(ctx, g.Members)
	return &network.Response{Status: http.StatusNoContent}
}

// syncGroups recomputes each person's groups and their admin role.
func (s *Service) syncGroups(ctx context.Context, people []string) {
	var groups []em.Group
	if err := s.R.List(ctx, "directory_groups", database.Filter{Limit: 1000}, &groups); err != nil {
		return
	}
	st, _ := s.settings(ctx)
	seen := map[string]bool{}
	for _, id := range people {
		if seen[id] {
			continue
		}
		seen[id] = true
		p, err := s.person(ctx, id)
		if err != nil {
			continue
		}
		p.Groups = []string{}
		for _, g := range groups {
			if containsExact(g.Members, id) {
				p.Groups = append(p.Groups, g.DisplayName)
			}
		}
		p.UpdatedAt = s.now().UTC()
		_ = s.R.Update(ctx, "directory_people", p.ID, p)
		s.syncAdmin(ctx, p.ID, p.Groups, st.SCIMAdminGroups)
	}
}

func containsExact(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func without(list []string, v string) []string {
	out := list[:0]
	for _, x := range list {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}

// scimRoutes are the SCIM endpoints.
func (s *Service) scimRoutes() []route {
	h := s.scimHandler
	static := func(v any) network.Handler {
		return h(func(context.Context, *network.Request) *network.Response { return scimReply(http.StatusOK, v) })
	}
	return []route{
		{network.MethodGet, SCIMPrefix + "/ServiceProviderConfig", static(map[string]any{
			"schemas": []string{"urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"},
			"patch":   map[string]bool{"supported": true}, "bulk": map[string]any{"supported": false},
			"filter": map[string]any{"supported": true, "maxResults": 1000}, "changePassword": map[string]bool{"supported": false},
			"sort": map[string]bool{"supported": false}, "etag": map[string]bool{"supported": false},
			"authenticationSchemes": []map[string]string{{"type": "oauthbearertoken", "name": "Bearer token"}}})},
		{network.MethodGet, SCIMPrefix + "/Users", h(s.listUsers)},
		{network.MethodPost, SCIMPrefix + "/Users", h(s.createUser)},
		{network.MethodGet, SCIMPrefix + "/Users/{id}", h(s.getUser)},
		{network.MethodPut, SCIMPrefix + "/Users/{id}", h(s.replaceUser)},
		{network.MethodPatch, SCIMPrefix + "/Users/{id}", h(s.patchUser)},
		{network.MethodDelete, SCIMPrefix + "/Users/{id}", h(s.deleteUser)},
		{network.MethodGet, SCIMPrefix + "/Groups", h(s.listGroups)},
		{network.MethodPost, SCIMPrefix + "/Groups", h(s.createGroup)},
		{network.MethodGet, SCIMPrefix + "/Groups/{id}", h(s.getGroup)},
		{network.MethodPut, SCIMPrefix + "/Groups/{id}", h(s.replaceGroup)},
		{network.MethodPatch, SCIMPrefix + "/Groups/{id}", h(s.patchGroup)},
		{network.MethodDelete, SCIMPrefix + "/Groups/{id}", h(s.deleteGroup)},
	}
}

type route struct {
	method  network.Method
	path    string
	handler network.Handler
}
