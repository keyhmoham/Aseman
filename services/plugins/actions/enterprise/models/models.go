// Package enterprise holds the records of the enterprise namespace: single
// sign-on providers, sign-ins in progress, SCIM's view of people and groups,
// organizations by email domain, and the node's enterprise settings (the
// SCIM token, SPIFFE workload identity).
package enterprise

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SSOProvider is an OpenID Connect identity provider (Okta, Entra ID, Google
// Workspace, Auth0, Keycloak, ...).
type SSOProvider struct {
	entity.Entity
	Slug         string `db:"slug" json:"slug"`
	Name         string `db:"name" json:"name"`
	Issuer       string `db:"issuer" json:"issuer"`
	ClientID     string `db:"client_id" json:"client_id"`
	ClientSecret string `db:"client_secret" json:"-"`
	// Domains are the email domains it signs in. With Required, people of
	// those domains may only sign in through it.
	Domains  []string `db:"domains" json:"domains"`
	Required bool     `db:"required" json:"required"`
	// GroupsClaim names the claim carrying group names; AdminGroups make an
	// administrator of whoever is in one.
	GroupsClaim string   `db:"groups_claim" json:"groups_claim,omitempty"`
	AdminGroups []string `db:"admin_groups" json:"admin_groups,omitempty"`
	Enabled     bool     `db:"enabled" json:"enabled"`
}

// SSOState is one sign-in in progress (single use, ten minutes).
type SSOState struct {
	entity.Entity
	Provider  string    `db:"provider" json:"provider"`
	Verifier  string    `db:"verifier" json:"-"`
	Nonce     string    `db:"nonce" json:"-"`
	Return    string    `db:"return_to" json:"return_to,omitempty"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

// SSOHandoff carries a finished sign-in from the browser redirect to the app
// that picks it up once.
type SSOHandoff struct {
	entity.Entity
	AccountID string    `db:"account_id" json:"account_id"`
	Sealed    string    `db:"sealed" json:"-"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

// Person is what the directory says of an account: its SCIM id is the
// account's id.
type Person struct {
	entity.Entity
	ExternalID string   `db:"external_id" json:"external_id,omitempty"`
	UserName   string   `db:"user_name" json:"user_name"`
	Email      string   `db:"email" json:"email"`
	GivenName  string   `db:"given_name" json:"given_name,omitempty"`
	FamilyName string   `db:"family_name" json:"family_name,omitempty"`
	Active     bool     `db:"active" json:"active"`
	Groups     []string `db:"groups" json:"groups"`
	// DisabledByDirectory: the directory deactivated the account, so the
	// directory may reactivate it (never one an administrator disabled).
	DisabledByDirectory bool `db:"disabled_by_directory" json:"disabled_by_directory,omitempty"`
}

// Group is a directory group.
type Group struct {
	entity.Entity
	ExternalID  string   `db:"external_id" json:"external_id,omitempty"`
	DisplayName string   `db:"display_name" json:"display_name"`
	Members     []string `db:"members" json:"members"`
}

// Organization is the people of one or more email domains.
type Organization struct {
	entity.Entity
	Name    string   `db:"name" json:"name"`
	Domains []string `db:"domains" json:"domains"`
	// SpaceID is the organization's shared project, which its people join.
	SpaceID string `db:"space_id" json:"space_id,omitempty"`
}

// SettingsID is the one settings record's id.
const SettingsID = "00000000000000000000000000000002"

// Settings are the node's enterprise settings.
type Settings struct {
	entity.Entity
	SCIMTokenHash   string   `db:"scim_token_hash" json:"-"`
	SCIMAdminGroups []string `db:"scim_admin_groups" json:"scim_admin_groups,omitempty"`
	// SPIFFE: the trust domain, where its JWT bundle is served, the audience
	// the agent runtime's JWT-SVIDs carry, and whether one is required.
	SPIFFETrustDomain string `db:"spiffe_trust_domain" json:"spiffe_trust_domain,omitempty"`
	SPIFFEBundleURL   string `db:"spiffe_bundle_url" json:"spiffe_bundle_url,omitempty"`
	SPIFFEAudience    string `db:"spiffe_audience" json:"spiffe_audience,omitempty"`
	SPIFFERequired    bool   `db:"spiffe_required" json:"spiffe_required"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func base(fields ...database.Field) []database.Field {
	return append([]database.Field{f("id", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}, fields...)
}

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b, j := database.KindString, database.KindTime, database.KindBool, database.KindJSON
	return []database.Model{
		{Name: "sso_providers", Table: "sso_providers", Fields: base(f("slug", s), f("name", s), f("issuer", s), f("client_id", s),
			f("client_secret", s), f("domains", j), f("required", b), f("groups_claim", s), f("admin_groups", j), f("enabled", b))},
		{Name: "sso_states", Table: "sso_states", Fields: base(f("provider", s), f("verifier", s), f("nonce", s), f("return_to", s), f("expires_at", t))},
		{Name: "sso_handoffs", Table: "sso_handoffs", Fields: base(f("account_id", s), f("sealed", s), f("expires_at", t))},
		{Name: "directory_people", Table: "directory_people", Fields: base(f("external_id", s), f("user_name", s), f("email", s),
			f("given_name", s), f("family_name", s), f("active", b), f("groups", j), f("disabled_by_directory", b))},
		{Name: "directory_groups", Table: "directory_groups", Fields: base(f("external_id", s), f("display_name", s), f("members", j))},
		{Name: "organizations", Table: "organizations", Fields: base(f("name", s), f("domains", j), f("space_id", s))},
		{Name: "enterprise_settings", Table: "enterprise_settings", Fields: base(f("scim_token_hash", s), f("scim_admin_groups", j),
			f("spiffe_trust_domain", s), f("spiffe_bundle_url", s), f("spiffe_audience", s), f("spiffe_required", b))},
	}
}
