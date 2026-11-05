// Package models holds the developer namespace's records: the organizations a
// person builds with, their members and API keys, and the log of every call.
package models

import (
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Roles of an organization member.
const (
	RoleOwner     = "owner"
	RoleAdmin     = "admin"
	RoleDeveloper = "developer"
	RoleViewer    = "viewer"
)

// Member states.
const (
	StatusActive  = "active"
	StatusInvited = "invited"
)

// Org is a team organization: its own wallet (owned by the org's id), keys,
// people and resources. A person's personal organization is not a row: it is
// the person's own account and wallet.
type Org struct {
	entity.Entity
	Name    string      `db:"name" json:"name"`
	OwnerID identity.ID `db:"owner_id" json:"owner_id"`
}

// Platform is a product environment owned by a developer organization. Its
// users, spaces, agents and apps are isolated from main Aseman and from every
// other platform unless the node admin sets MainAccess (a boolean bridge to
// the shared Aseman environment, both ways).
type Platform struct {
	entity.Entity
	// OrgID is the team org's id, or the account's id for a personal org.
	OrgID identity.ID `db:"org_id" json:"org_id"`
	Slug  string      `db:"slug" json:"slug"`
	Name  string      `db:"name" json:"name"`
	// MainAccess is set only by the node admin: when true, this platform's
	// users see main Aseman entities and main Aseman users see this
	// platform's. Other platforms stay invisible either way.
	MainAccess bool `db:"main_access" json:"main_access"`

	// The platform's frontend: an App UI the agents of a space built (Elpian
	// or web), published by an owner or admin of the organization as what the
	// platform's people open. Empty FrontendProxyID: no frontend.
	FrontendProxyID string `db:"frontend_proxy_id" json:"frontend_proxy_id,omitempty"`
	FrontendSpaceID string `db:"frontend_space_id" json:"frontend_space_id,omitempty"`
	// FrontendApp is the app's project directory on the space's computer.
	FrontendApp   string `db:"frontend_app" json:"frontend_app,omitempty"`
	FrontendTitle string `db:"frontend_title" json:"frontend_title,omitempty"`
	// FrontendUI is "elpian" (a program the client runs natively, at
	// FrontendEntry of the app's server) or "web".
	FrontendUI    string `db:"frontend_ui" json:"frontend_ui,omitempty"`
	FrontendEntry string `db:"frontend_entry" json:"frontend_entry,omitempty"`
	// FrontendWiring is the JSON of the app's [Wiring]: the space's agents and
	// apps its frontend and backend use. The platform's people reach those and
	// nothing else of the space.
	FrontendWiring string `db:"frontend_wiring" json:"-"`
	// FrontendBy is the person who published it: the platform's use of the
	// space's agents and apps runs as, and is billed to, them.
	FrontendBy identity.ID `db:"frontend_by" json:"frontend_by,omitempty"`
	FrontendAt time.Time   `db:"frontend_at" json:"frontend_at,omitempty"`
}

// Wiring is what an app built in a space is wired to: the space's agents it
// asks and the apps (with their microtools) it calls, as the builder was
// given them in APPS.json. A published platform frontend reaches exactly
// these; anything else of the space is refused.
type Wiring struct {
	Agents []WiredAgent `json:"agents"`
	Apps   []WiredApp   `json:"apps"`
}

// WiredAgent is a space agent an app asks.
type WiredAgent struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// WiredApp is a space app an app calls, and the microtools it may call.
type WiredApp struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// DisplayName is how people see the app (Name is what the API calls it).
	DisplayName string   `json:"display_name,omitempty"`
	Microtools  []string `json:"microtools,omitempty"`
}

func wiredName(ref, id, name string) bool {
	ref = strings.TrimSpace(ref)
	return ref != "" && (ref == id || strings.EqualFold(ref, name))
}

// AllowsAgent reports whether [ref] (an agent's id or name) is wired.
func (w Wiring) AllowsAgent(ref string) bool {
	for _, a := range w.Agents {
		if wiredName(ref, a.ID, a.Name) {
			return true
		}
	}
	return false
}

// AllowsApp reports whether [ref] (an app's id or name) is wired, and, when
// [microtool] is given, whether that microtool of it is (an app wired with
// no microtools listed allows all of its own).
func (w Wiring) AllowsApp(ref, microtool string) bool {
	for _, a := range w.Apps {
		if !wiredName(ref, a.ID, a.Name) {
			continue
		}
		if microtool == "" || len(a.Microtools) == 0 {
			return true
		}
		for _, m := range a.Microtools {
			if m == microtool {
				return true
			}
		}
		return false
	}
	return false
}

// PlatformFrontend is a platform with its published frontend, as the gateway
// and the spaces namespace see it.
type PlatformFrontend struct {
	PlatformID string `json:"platform_id"`
	OrgID      string `json:"org_id"`
	Slug       string `json:"slug"`
	Name       string `json:"name"`
	MainAccess bool   `json:"main_access"`
	ProxyID    string `json:"proxy_id"`
	SpaceID    string `json:"space_id"`
	App        string `json:"app"`
	Title      string `json:"title"`
	UI         string `json:"ui"`
	Entry      string `json:"entry,omitempty"`
	Publisher  string `json:"publisher"`
	Wiring     Wiring `json:"wiring"`
}

// AppAccess is a developer API key made for one app's server: the spaces
// namespace writes it into that server's settings only (never the page, never
// an agent's reply).
type AppAccess struct {
	KeyID    string `json:"key_id"`
	Secret   string `json:"secret"`
	Org      string `json:"org"`
	Platform string `json:"platform,omitempty"`
}

// FrontendApp is an app a person may publish as a platform's frontend (one
// the agents of a space they belong to built and published there).
type FrontendApp struct {
	ProxyID   string `json:"proxy_id"`
	SpaceID   string `json:"space_id"`
	SpaceName string `json:"space_name,omitempty"`
	App       string `json:"app"`
	Title     string `json:"title"`
	UI        string `json:"ui"`
	Entry     string `json:"entry,omitempty"`
	Kind      string `json:"kind,omitempty"`
	Audience  string `json:"audience,omitempty"`
	Wiring    Wiring `json:"wiring"`
	UpdatedAt string `json:"updated_at,omitempty"`
}

// WorkflowRun is one run (or plan) of a workflow installer. Secrets are never
// stored; the report has them redacted.
type WorkflowRun struct {
	entity.Entity
	OrgID     identity.ID `db:"org_id" json:"org_id"`
	KeyID     string      `db:"key_id" json:"key_id,omitempty"`
	CreatedBy identity.ID `db:"created_by" json:"created_by"`
	Name      string      `db:"name" json:"name"`
	Version   string      `db:"version" json:"version,omitempty"`
	Mode      string      `db:"mode" json:"mode"`
	Status    string      `db:"status" json:"status"`
	Error     string      `db:"error" json:"error,omitempty"`
	// Definition is the workflow document as it was given.
	Definition string `db:"definition" json:"-"`
	// Report is the JSON of the run's report.
	Report      string    `db:"report" json:"-"`
	ResumedFrom string    `db:"resumed_from" json:"resumed_from,omitempty"`
	StartedAt   time.Time `db:"started_at" json:"started_at"`
	FinishedAt  time.Time `db:"finished_at" json:"finished_at,omitempty"`
}

// Member is a person in an organization.
type Member struct {
	entity.Entity
	OrgID     identity.ID `db:"org_id" json:"org_id"`
	AccountID identity.ID `db:"account_id" json:"account_id"`
	Handle    string      `db:"handle" json:"handle"`
	Role      string      `db:"role" json:"role"`
	Status    string      `db:"status" json:"status"`
	InvitedBy identity.ID `db:"invited_by" json:"invited_by"`
}

// Key is a developer API key. The secret is never stored: only its hash.
type Key struct {
	entity.Entity
	// OrgID is the team organization's id, or the account's id for the
	// personal organization.
	OrgID       identity.ID `db:"org_id" json:"org_id"`
	Name        string      `db:"name" json:"name"`
	Prefix      string      `db:"prefix" json:"prefix"`
	Last4       string      `db:"last4" json:"last4"`
	Hash        string      `db:"hash" json:"-"`
	Permissions string      `db:"permissions" json:"-"` // JSON
	Limits      string      `db:"limits" json:"-"`      // JSON
	Status      string      `db:"status" json:"status"`
	CreatedBy   identity.ID `db:"created_by" json:"created_by"`
	LastUsedAt  time.Time   `db:"last_used_at" json:"last_used_at"`
	ExpiresAt   time.Time   `db:"expires_at" json:"expires_at"`
	Requests    int64       `db:"requests" json:"requests"`
	// MonthKey is the calendar month (2026-10) MonthSpent counts.
	MonthKey   string `db:"month_key" json:"month_key"`
	MonthSpent int64  `db:"month_spent" json:"month_spent"`
}

// Computer is a machine an organization runs: a VM at the node's sandbox
// provider, with its files on a persistent /workspace volume.
type Computer struct {
	entity.Entity
	OrgID    identity.ID `db:"org_id" json:"org_id"`
	Name     string      `db:"name" json:"name"`
	Image    string      `db:"image" json:"image"`
	CPU      float64     `db:"cpu" json:"cpu"`
	MemoryMB int64       `db:"memory_mb" json:"memory_mb"`
	DiskMB   int64       `db:"disk_mb" json:"disk_mb"`
	Status   string      `db:"status" json:"status"`
	// VMID and VMName identify the machine at the provider; VMType is its kind.
	VMID      string      `db:"vm_id" json:"vm_id"`
	VMName    string      `db:"vm_name" json:"vm_name"`
	VMType    string      `db:"vm_type" json:"vm_type"`
	CreatedBy identity.ID `db:"created_by" json:"created_by"`
	// LastActiveAt is the last command, for the idle stop.
	LastActiveAt time.Time `db:"last_active_at" json:"last_active_at"`
	// RunStartedAt is when the current run began (zero while stopped);
	// RunBilled is what that run has been charged so far (ledger units) and
	// Seconds the time of earlier runs.
	RunStartedAt time.Time `db:"run_started_at" json:"run_started_at"`
	RunBilled    int64     `db:"run_billed" json:"run_billed"`
	Seconds      int64     `db:"seconds" json:"seconds"`
}

// File is a stored file; its bytes are kept under Key.
type File struct {
	entity.Entity
	OrgID   identity.ID `db:"org_id" json:"org_id"`
	Name    string      `db:"name" json:"name"`
	Size    int64       `db:"size" json:"size"`
	Mime    string      `db:"mime" json:"mime"`
	Purpose string      `db:"purpose" json:"purpose"`
	Key     string      `db:"key" json:"-"`
}

// Settings are an organization's own limits, and what it has spent this month.
// The id is the organization's (the account's, for the personal one).
type Settings struct {
	entity.Entity
	MonthlyCap int64  `db:"monthly_cap" json:"monthly_cap"`
	LowBalance int64  `db:"low_balance" json:"low_balance"`
	MonthKey   string `db:"month_key" json:"month_key"`
	MonthSpent int64  `db:"month_spent" json:"month_spent"`
	// StorageBilledAt is how far the organization's stored files have been
	// charged for; StorageFrac is the part of a ledger unit not yet charged.
	StorageBilledAt time.Time `db:"storage_billed_at" json:"storage_billed_at"`
	StorageFrac     float64   `db:"storage_frac" json:"storage_frac"`
}

// Video job states.
const (
	VideoPending   = "pending"
	VideoCompleted = "completed"
	VideoFailed    = "failed"
)

// VideoJob is a video an organization asked for: generated by the provider in
// the background and fetched by its id. It is charged when it starts and
// refunded if the provider fails it.
type VideoJob struct {
	entity.Entity
	OrgID   identity.ID `db:"org_id" json:"org_id"`
	KeyID   string      `db:"key_id" json:"key_id"`
	KeyName string      `db:"key_name" json:"key_name"`
	// Model is the canonical model and Provider the slug of the provider
	// running it; Operation is the provider's reference to the job (JSON).
	Model      string `db:"model" json:"model"`
	Provider   string `db:"provider" json:"provider"`
	Operation  string `db:"operation" json:"-"`
	Status     string `db:"status" json:"status"`
	Seconds    int64  `db:"seconds" json:"seconds"`
	Resolution string `db:"resolution" json:"resolution"`
	Cost       int64  `db:"cost" json:"cost"`
	Error      string `db:"error" json:"error"`
	// Payee is who the charge was paid to, and pays the refund.
	Payee identity.ID `db:"payee" json:"-"`
}

// Log is one request made with a key (or from the console's playground).
type Log struct {
	ID             string    `db:"id" json:"id"`
	OrgID          string    `db:"org_id" json:"org_id"`
	KeyID          string    `db:"key_id" json:"key_id"`
	KeyName        string    `db:"key_name" json:"key_name"`
	Service        string    `db:"service" json:"service"`
	Method         string    `db:"method" json:"method"`
	Path           string    `db:"path" json:"path"`
	Status         int64     `db:"status" json:"status"`
	LatencyMs      int64     `db:"latency_ms" json:"latency_ms"`
	Model          string    `db:"model" json:"model"`
	RequestedModel string    `db:"requested_model" json:"requested_model"`
	Provider       string    `db:"provider" json:"provider"`
	TokensIn       int64     `db:"tokens_in" json:"tokens_in"`
	TokensOut      int64     `db:"tokens_out" json:"tokens_out"`
	Cost           int64     `db:"cost" json:"cost"`
	Request        string    `db:"request" json:"request"`
	Response       string    `db:"response" json:"response"`
	Error          string    `db:"error" json:"error"`
	CreatedAt      time.Time `db:"created_at" json:"created_at"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// fi is an indexed field: the ones the namespace looks records up by.
func fi(name string, k database.Kind) database.Field {
	return database.Field{Name: name, Kind: k, Index: true}
}

// Models are registered by the namespace's lifecycle.
func Models() []database.Model {
	return []database.Model{
		{Name: "dev_orgs", Table: "dev_orgs", Fields: []database.Field{
			f("id", database.KindString), f("name", database.KindString), f("owner_id", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_platforms", Table: "dev_platforms", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), fi("slug", database.KindString),
			f("name", database.KindString), f("main_access", database.KindBool),
			fi("frontend_proxy_id", database.KindString), f("frontend_space_id", database.KindString),
			f("frontend_app", database.KindString), f("frontend_title", database.KindString),
			f("frontend_ui", database.KindString), f("frontend_entry", database.KindString),
			f("frontend_wiring", database.KindString), f("frontend_by", database.KindString),
			f("frontend_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_members", Table: "dev_members", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), fi("account_id", database.KindString),
			f("handle", database.KindString), f("role", database.KindString), f("status", database.KindString),
			f("invited_by", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_keys", Table: "dev_keys", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), f("name", database.KindString),
			f("prefix", database.KindString), f("last4", database.KindString), fi("hash", database.KindString),
			f("permissions", database.KindString), f("limits", database.KindString), f("status", database.KindString),
			f("created_by", database.KindString), f("last_used_at", database.KindTime), f("expires_at", database.KindTime),
			f("requests", database.KindInt64), f("month_key", database.KindString), f("month_spent", database.KindInt64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_computers", Table: "dev_computers", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), f("name", database.KindString),
			f("image", database.KindString), f("cpu", database.KindFloat64), f("memory_mb", database.KindInt64),
			f("disk_mb", database.KindInt64), fi("status", database.KindString), f("vm_id", database.KindString),
			f("vm_name", database.KindString), f("vm_type", database.KindString), f("created_by", database.KindString),
			f("last_active_at", database.KindTime), f("run_started_at", database.KindTime), f("run_billed", database.KindInt64),
			f("seconds", database.KindInt64), f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_files", Table: "dev_files", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), f("name", database.KindString),
			f("size", database.KindInt64), f("mime", database.KindString), f("purpose", database.KindString),
			f("key", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_settings", Table: "dev_settings", Fields: []database.Field{
			f("id", database.KindString), f("monthly_cap", database.KindInt64), f("low_balance", database.KindInt64),
			f("month_key", database.KindString), f("month_spent", database.KindInt64),
			f("storage_billed_at", database.KindTime), f("storage_frac", database.KindFloat64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_videos", Table: "dev_videos", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), f("key_id", database.KindString),
			f("key_name", database.KindString), f("model", database.KindString), f("provider", database.KindString),
			f("operation", database.KindString), f("status", database.KindString), f("seconds", database.KindInt64),
			f("resolution", database.KindString), f("cost", database.KindInt64), f("error", database.KindString),
			f("payee", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_workflow_runs", Table: "dev_workflow_runs", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), f("key_id", database.KindString),
			f("created_by", database.KindString), f("name", database.KindString), f("version", database.KindString),
			f("mode", database.KindString), fi("status", database.KindString), f("error", database.KindString),
			f("definition", database.KindString), f("report", database.KindString), f("resumed_from", database.KindString),
			f("started_at", database.KindTime), f("finished_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "dev_logs", Table: "dev_logs", Fields: []database.Field{
			f("id", database.KindString), fi("org_id", database.KindString), fi("key_id", database.KindString),
			f("key_name", database.KindString), f("service", database.KindString), f("method", database.KindString),
			f("path", database.KindString), f("status", database.KindInt64), f("latency_ms", database.KindInt64),
			f("model", database.KindString), f("requested_model", database.KindString), f("provider", database.KindString),
			f("tokens_in", database.KindInt64), f("tokens_out", database.KindInt64), f("cost", database.KindInt64),
			f("request", database.KindString), f("response", database.KindString), f("error", database.KindString),
			f("created_at", database.KindTime),
		}},
	}
}
