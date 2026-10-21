package spaces

import (
	"context"
	"encoding/json"
	"sort"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The agents and tools of the platform admins space read the node's database
// directly: agents through the db_tables and db_read tools, tool backends
// through the same two host calls (spaces/db_tables, spaces/db_read). Access
// is read only, goes through the database adapter (no native queries), and
// credentials are redacted as on the admin console's tables. It is granted
// only in the admins space and only while the person the work is done for is
// an active platform administrator, so a non-admin member of that project
// cannot read the database through its agents.

const (
	dbReadDefaultLimit = 50
	dbReadMaxLimit     = 200
)

// dbTools are the agent tools of the admins space.
func dbTools() []vmm.Tool {
	str := func(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
	obj := func(d string) map[string]any { return map[string]any{"type": "object", "description": d} }
	return []vmm.Tool{
		{
			Name: "db_tables", Kind: "tool",
			Description: "List the tables (models) of the Aseman platform database and their fields.",
			Usage:       "Read-only access to the node's own database, available in the platform admins space. Call this first to learn the table and field names to pass to db_read. Pass model to see one table.",
			Example:     `{"model":"accounts"}`,
			Parameters:  map[string]any{"type": "object", "properties": map[string]any{"model": str("Optional table name; omitted lists every table.")}},
		},
		{
			Name: "db_read", Kind: "tool",
			Description: "Read records from a table of the Aseman platform database (read only).",
			Usage:       "Pass id to read one record, or filter with equal/in/gt/lt on the table's fields, with order_by, asc, limit (1..200, default 50) and offset to page. The total count of matching records is returned with each page. Passwords, keys and tokens come back as [redacted]. Nothing can be written.",
			Example:     `{"model":"accounts","equal":{"role":"admin"},"order_by":"created_at","limit":20}`,
			Parameters: map[string]any{"type": "object", "properties": map[string]any{
				"model":    str("Table name from db_tables."),
				"id":       str("Optional record id; returns that one record."),
				"equal":    obj("Optional field -> exact value."),
				"in":       obj("Optional field -> list of accepted values."),
				"gt":       obj("Optional field -> value the field must be greater than."),
				"lt":       obj("Optional field -> value the field must be less than."),
				"order_by": str("Optional field to sort by."),
				"asc":      map[string]any{"type": "boolean", "description": "Sort ascending; default descending."},
				"limit":    map[string]any{"type": "integer", "description": "Records per page, 1..200; default 50."},
				"offset":   map[string]any{"type": "integer", "description": "Records to skip."},
			}, "required": []string{"model"}},
		},
	}
}

func dbActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "db_tables", Summary: "Admins space: list the platform database's tables", Handler: s.dbTablesAction},
		helper.Action{Namespace: "spaces", Name: "db_read", Summary: "Admins space: read records from the platform database", Handler: s.dbReadAction},
	}
}

// dbAccess allows database reads in a space for the person the work is done
// for: the space must be the admins space and the person an active platform
// administrator.
func (s *Service) dbAccess(ctx context.Context, spaceID, actor identity.ID) error {
	admins, err := s.AdminsSpace(ctx)
	if err != nil {
		return err
	}
	return s.checkDBAccess(ctx, admins, spaceID, actor)
}

func (s *Service) checkDBAccess(ctx context.Context, admins, spaceID, actor identity.ID) error {
	if admins.IsZero() || admins != spaceID {
		return errs.Permission("database access is only available in the platform admins space")
	}
	if actor.IsZero() || !s.isPlatformAdmin(ctx, actor) {
		return errs.Permission("database access is only available to platform administrators")
	}
	return nil
}

func (s *Service) isPlatformAdmin(ctx context.Context, id identity.ID) bool {
	var a account.Account
	if s.R.Get(ctx, "accounts", id, &a) != nil {
		return false
	}
	handle := s.K.Env()["admin_handle"]
	return a.Kind == account.KindUser && a.Status == account.StatusActive && (a.Role == "admin" || (handle != "" && a.Handle == handle))
}

// actorOf is the person a tool call is made for.
func actorOf(ctx context.Context) identity.ID {
	if raw := vmm.ExecutionFrom(ctx).ActorID; raw != "" {
		if id, err := identity.Parse(raw); err == nil {
			return id
		}
		return identity.ID{}
	}
	return helper.Actor(ctx)
}

// dbToolsAllowed reports whether the agents of a space are offered the
// database tools in this context.
func (s *Service) dbToolsAllowed(ctx context.Context, spaceID identity.ID) bool {
	return s.dbAccess(ctx, spaceID, actorOf(ctx)) == nil
}

func kindName(k database.Kind) string {
	switch k {
	case database.KindInt64:
		return "int"
	case database.KindFloat64:
		return "float"
	case database.KindBool:
		return "bool"
	case database.KindJSON:
		return "json"
	case database.KindTime:
		return "time"
	case database.KindBytes:
		return "bytes"
	default:
		return "string"
	}
}

func (s *Service) dbModel(name string) (database.Model, bool) {
	for _, m := range s.R.DB.Models() {
		if m.Name == name {
			return m, true
		}
	}
	return database.Model{}, false
}

// dbTables describes the database's tables, or one of them.
func (s *Service) dbTables(model string) (map[string]any, error) {
	models := s.R.DB.Models()
	sort.Slice(models, func(i, j int) bool { return models[i].Name < models[j].Name })
	out := []map[string]any{}
	for _, m := range models {
		if model != "" && m.Name != model {
			continue
		}
		fields := []map[string]any{}
		for _, f := range m.Fields {
			field := map[string]any{"name": f.Name, "type": kindName(f.Kind)}
			if helper.CredentialField(f.Name) {
				field["redacted"] = true
			}
			fields = append(fields, field)
		}
		out = append(out, map[string]any{"name": m.Name, "fields": fields})
	}
	if model != "" && len(out) == 0 {
		return nil, errs.NotFound("no table " + model + "; call db_tables without a model to list them")
	}
	return map[string]any{"tables": out}, nil
}

type dbReadInput struct {
	Model   string           `json:"model"`
	ID      string           `json:"id"`
	Equal   map[string]any   `json:"equal"`
	In      map[string][]any `json:"in"`
	Gt      map[string]any   `json:"gt"`
	Lt      map[string]any   `json:"lt"`
	OrderBy string           `json:"order_by"`
	Asc     bool             `json:"asc"`
	Limit   int              `json:"limit"`
	Offset  int              `json:"offset"`
}

// dbRead reads one record or a page of records from a table.
func (s *Service) dbRead(ctx context.Context, in dbReadInput) (map[string]any, error) {
	in.Model = strings.TrimSpace(in.Model)
	m, ok := s.dbModel(in.Model)
	if !ok {
		return nil, errs.NotFound("no table " + in.Model + "; call db_tables to list them")
	}
	if in.ID != "" {
		row := map[string]any{}
		if err := s.R.DB.Get(ctx, m.Name, in.ID, &row); err != nil {
			return nil, err
		}
		return map[string]any{"model": m.Name, "record": helper.RedactCredentials(row)}, nil
	}
	// Only the table's own fields can be filtered or sorted on; filtering on a
	// credential would reveal it a guess at a time.
	check := func(field string) error {
		if _, ok := m.Field(field); !ok {
			return errs.InvalidArgument("table " + m.Name + " has no field " + field)
		}
		if helper.CredentialField(field) {
			return errs.Permission("field " + field + " cannot be filtered or sorted on")
		}
		return nil
	}
	for _, set := range []map[string]any{in.Equal, in.Gt, in.Lt} {
		for field := range set {
			if err := check(field); err != nil {
				return nil, err
			}
		}
	}
	for field := range in.In {
		if err := check(field); err != nil {
			return nil, err
		}
	}
	if in.OrderBy != "" {
		if err := check(in.OrderBy); err != nil {
			return nil, err
		}
	}
	if in.Limit <= 0 {
		in.Limit = dbReadDefaultLimit
	}
	in.Limit = min(in.Limit, dbReadMaxLimit)
	in.Offset = max(in.Offset, 0)
	filter := database.Filter{Equal: in.Equal, In: in.In, GreaterThan: in.Gt, LessThan: in.Lt}
	total, err := s.R.DB.Count(ctx, m.Name, filter)
	if err != nil {
		return nil, err
	}
	filter.OrderBy, filter.Asc, filter.Limit, filter.Offset = in.OrderBy, in.Asc, in.Limit, in.Offset
	rows := []map[string]any{}
	if err := s.R.DB.List(ctx, m.Name, filter, &rows); err != nil {
		return nil, err
	}
	return map[string]any{
		"model": m.Name, "total": total, "offset": in.Offset, "count": len(rows),
		"has_more": int64(in.Offset+len(rows)) < total, "records": helper.RedactCredentials(rows),
	}, nil
}

// dbTool runs db_tables or db_read for an agent of a space.
func (s *Service) dbTool(ctx context.Context, spaceID identity.ID, toolName, argsJSON string) (string, error) {
	if err := s.dbAccess(ctx, spaceID, actorOf(ctx)); err != nil {
		return "", err
	}
	var out map[string]any
	var err error
	if toolName == "db_tables" {
		var in struct {
			Model string `json:"model"`
		}
		_ = json.Unmarshal([]byte(argsJSON), &in)
		out, err = s.dbTables(strings.TrimSpace(in.Model))
	} else {
		var in dbReadInput
		if argsJSON != "" {
			if jerr := json.Unmarshal([]byte(argsJSON), &in); jerr != nil {
				return "", errs.InvalidArgument("db_read takes a JSON object: " + jerr.Error())
			}
		}
		out, err = s.dbRead(ctx, in)
	}
	if err != nil {
		return "", err
	}
	raw, _ := json.Marshal(out)
	return string(raw), nil
}

// dbCaller checks a db_* action: the caller (a person, or a tool's account
// acting inside its call's scope) must be a member of the admins space, and
// the person the work is done for a platform administrator.
func (s *Service) dbCaller(ctx context.Context, req *api.ActionRequest, rawSpace string) (identity.ID, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return identity.ID{}, err
	}
	spaceID, err := identity.Parse(rawSpace)
	if err != nil {
		return identity.ID{}, errs.InvalidArgument("space required")
	}
	if _, err := s.SpaceMembership(ctx, spaceID, req.Caller.ID); err != nil {
		return identity.ID{}, errs.Permission("not a member of space " + spaceID.String())
	}
	actor := req.Caller.ID
	if req.Caller.Kind == "bot" {
		actor = actorOf(ctx)
	}
	return spaceID, s.dbAccess(ctx, spaceID, actor)
}

func (s *Service) dbTablesAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Model string `json:"model"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if _, err := s.dbCaller(ctx, req, in.Space); err != nil {
		return nil, err
	}
	out, err := s.dbTables(strings.TrimSpace(in.Model))
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

func (s *Service) dbReadAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		dbReadInput
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if _, err := s.dbCaller(ctx, req, in.Space); err != nil {
		return nil, err
	}
	out, err := s.dbRead(ctx, in.dbReadInput)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}
