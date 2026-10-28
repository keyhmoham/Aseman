package enterprise

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func (s *Service) actions() []api.Action {
	open := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "enterprise", Name: name, Summary: summary, Handler: h}
	}
	admin := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "enterprise", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			if !s.isAdmin(ctx, req.Caller.ID) {
				return nil, errs.Permission("administrator required")
			}
			return h(ctx, req)
		}}
	}
	return []api.Action{
		open("sso_discover", "Whether an email signs in with single sign-on, and with which provider", s.ssoDiscover),
		open("sso_start", "Start signing in with single sign-on: the provider's URL", s.ssoStart),
		open("sso_complete", "Pick up a finished single sign-on (once)", s.ssoComplete),
		admin("providers_list", "Admin: single sign-on providers", s.providersList),
		admin("provider_save", "Admin: add or change a single sign-on provider", s.providerSave),
		admin("provider_delete", "Admin: remove a single sign-on provider", s.providerDelete),
		admin("scim_token_new", "Admin: a new SCIM token for the directory (shown once; replaces the old)", s.scimTokenNew),
		admin("settings_get", "Admin: enterprise settings (SCIM, workload identity)", s.settingsGet),
		admin("settings_set", "Admin: set the SCIM admin groups and workload identity", s.settingsSet),
		admin("organizations_list", "Admin: organizations by email domain", s.orgsList),
		admin("organization_save", "Admin: add or change an organization (name, domains, shared project)", s.orgSave),
		admin("organization_delete", "Admin: remove an organization", s.orgDelete),
		admin("directory_list", "Admin: the people the directory provisioned", s.directoryList),
		admin("deprovision", "Admin: offboard a person now (disable, end sessions, revoke connections, stop their computers)", s.deprovision),
	}
}

func (s *Service) ssoDiscover(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email string `json:"email"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	var rows []em.SSOProvider
	_ = s.R.List(ctx, "sso_providers", database.Filter{Equal: map[string]any{"enabled": true}, Limit: 50}, &rows)
	providers := []map[string]string{}
	for _, p := range rows {
		providers = append(providers, map[string]string{"slug": p.Slug, "name": p.Name})
	}
	out := map[string]any{"sso": false, "providers": providers}
	if p, ok := s.providerFor(ctx, in.Email); ok {
		out["sso"], out["slug"], out["name"], out["required"] = true, p.Slug, p.Name, p.Required
	}
	return helper.JSON(out)
}

func (s *Service) ssoStart(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email  string `json:"email,omitempty"`
		Slug   string `json:"provider,omitempty"`
		Return string `json:"return,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	u, err := s.StartSSO(ctx, in.Email, in.Slug, in.Return)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"url": u})
}

func (s *Service) ssoComplete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Handoff string `json:"handoff"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	out, err := s.CompleteSSO(ctx, in.Handoff)
	if err != nil {
		return nil, err
	}
	if id, err := identity.Parse(stringOf(out["account_id"])); err == nil {
		out["home_space_id"] = s.homeSpace(ctx, id)
	}
	return helper.JSON(out)
}

func stringOf(v any) string {
	s, _ := v.(string)
	return s
}

func (s *Service) homeSpace(ctx context.Context, owner identity.ID) string {
	var rows []struct {
		ID string `json:"id"`
	}
	if err := s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "home": true}, Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return ""
	}
	return rows[0].ID
}

func (s *Service) providersList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var rows []em.SSOProvider
	if err := s.R.List(ctx, "sso_providers", database.Filter{Limit: 100}, &rows); err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for _, p := range rows {
		out = append(out, map[string]any{"provider": p, "has_secret": p.ClientSecret != ""})
	}
	return helper.JSON(map[string]any{"providers": out, "redirect_uri": ssoRedirect()})
}

func (s *Service) providerSave(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		em.SSOProvider
		Secret string `json:"client_secret,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := s.SaveProvider(ctx, in.SSOProvider, in.Secret)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"provider": p, "redirect_uri": ssoRedirect()})
}

func (s *Service) providerDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Slug string `json:"slug"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	var rows []em.SSOProvider
	if err := s.R.List(ctx, "sso_providers", database.Filter{Equal: map[string]any{"slug": in.Slug}, Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return nil, errs.NotFound("provider")
	}
	if err := s.R.Delete(ctx, "sso_providers", rows[0].ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) scimTokenNew(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	token, err := s.NewSCIMToken(ctx)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"token": token, "base_url": publicURL() + SCIMPrefix})
}

func (s *Service) settingsGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	st, _ := s.settings(ctx)
	return helper.JSON(map[string]any{"settings": st, "scim_configured": st.SCIMTokenHash != "", "scim_base_url": publicURL() + SCIMPrefix,
		"sso_redirect_uri": ssoRedirect()})
}

func (s *Service) settingsSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		SCIMAdminGroups   []string `json:"scim_admin_groups"`
		SPIFFETrustDomain string   `json:"spiffe_trust_domain"`
		SPIFFEBundleURL   string   `json:"spiffe_bundle_url"`
		SPIFFEAudience    string   `json:"spiffe_audience"`
		SPIFFERequired    bool     `json:"spiffe_required"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.SPIFFERequired && (in.SPIFFEBundleURL == "" || in.SPIFFETrustDomain == "") {
		return nil, errs.InvalidArgument("requiring workload identity needs its trust domain and bundle address")
	}
	st, exists := s.settings(ctx)
	st.SCIMAdminGroups, st.SPIFFETrustDomain, st.SPIFFEBundleURL, st.SPIFFEAudience, st.SPIFFERequired =
		in.SCIMAdminGroups, in.SPIFFETrustDomain, in.SPIFFEBundleURL, in.SPIFFEAudience, in.SPIFFERequired
	if err := s.saveSettings(ctx, st, exists); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"settings": st})
}

func (s *Service) orgsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var rows []em.Organization
	if err := s.R.List(ctx, "organizations", database.Filter{Limit: 200}, &rows); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"organizations": rows})
}

func (s *Service) orgSave(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in em.Organization
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Name == "" || len(in.Domains) == 0 {
		return nil, errs.InvalidArgument("an organization needs a name and at least one email domain")
	}
	now := s.now().UTC()
	if in.ID.IsZero() {
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return nil, err
		}
		in.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
		if err := s.R.CreateID(ctx, "organizations", id, &in); err != nil {
			return nil, err
		}
	} else {
		in.UpdatedAt = now
		if err := s.R.Update(ctx, "organizations", in.ID, &in); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"organization": in})
}

func (s *Service) orgDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid id")
	}
	if err := s.R.Delete(ctx, "organizations", id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) directoryList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var rows []em.Person
	if err := s.R.List(ctx, "directory_people", database.Filter{OrderBy: "created_at", Limit: 1000}, &rows); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"people": rows})
}

func (s *Service) deprovision(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account string `json:"account"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Account)
	if err != nil {
		return nil, errs.InvalidArgument("invalid account")
	}
	if id == req.Caller.ID {
		return nil, errs.InvalidArgument("you cannot offboard yourself")
	}
	done, err := s.Deprovision(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"done": done})
}
