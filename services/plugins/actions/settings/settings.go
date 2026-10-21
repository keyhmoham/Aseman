// Package settings owns mutable platform policy. Provider credentials remain in
// llm. Policy keys:
//   - categories: the marketplace categories offered when publishing;
//   - universal_system_prompt: instructions prepended to every agent turn
//     (read by spaces through Instructions);
//   - pricing: what execution costs — the sandbox, apps, and
//     agents' time (read by bots through Pricing);
//   - machine: the size of a project's computer — sold size, idle reserve and
//     ceiling (read by spaces and the Modal adapter through Machine);
//   - admins_space: the project every platform administrator is kept a member
//     of (read and set by spaces through AdminsSpace and SetAdminsSpace).
package settings

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/settings/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"math"
	"strconv"
	"strings"
	"time"
)

type Service struct {
	K api.Kernel
	R *repo.Repo
}

var allowedKeys = map[string]bool{"categories": true, "universal_system_prompt": true, "pricing": true, "machine": true, "admins_space": true}

func (s *Service) id() string { return s.K.NodeID().String() + "0000000000000001" }
func defaults() map[string]any {
	return map[string]any{"categories": []string{"general", "research", "coding", "design", "marketing", "operations", "finance", "education", "support"}, "universal_system_prompt": "", "pricing": models.DefaultPricing(), "machine": models.Machine{}, "admins_space": ""}
}

// Pricing returns the node's execution price list.
func (s *Service) Pricing(ctx context.Context) (models.Pricing, error) {
	row, e := s.Get(ctx)
	if e != nil {
		return models.DefaultPricing(), e
	}
	p, e := parsePricing(row.Values["pricing"])
	if e != nil {
		return models.DefaultPricing(), nil
	}
	return p, nil
}

// parsePricing reads a stored or submitted price list; a missing one is the
// default, and unknown fields or negative rates are refused.
func parsePricing(v any) (models.Pricing, error) {
	if v == nil {
		return models.DefaultPricing(), nil
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return models.Pricing{}, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	p := models.DefaultPricing()
	if err := dec.Decode(&p); err != nil {
		return models.Pricing{}, errs.InvalidArgument("invalid pricing: " + err.Error())
	}
	if !p.Sandbox.Valid() || !p.Tool.Valid() || p.AgentPerMinute < 0 || p.StorageGBMonth < 0 {
		return models.Pricing{}, errs.InvalidArgument("prices cannot be negative")
	}
	return p, nil
}

// Machine returns the size of a project's computer with every field filled in:
// what the admin set, else the node's configured sandbox size, else the defaults,
// with the reserve and ceiling derived from the sold size when not set.
func (s *Service) Machine(ctx context.Context) (models.Machine, error) {
	row, e := s.Get(ctx)
	if e != nil {
		return effectiveMachine(models.Machine{}, s.K.Env()), e
	}
	stored, err := parseMachine(row.Values["machine"])
	if err != nil {
		stored = models.Machine{}
	}
	return effectiveMachine(stored, s.K.Env()), nil
}

func envFloat(env map[string]string, key string, fallback float64) float64 {
	if v, err := strconv.ParseFloat(env[key], 64); err == nil && v > 0 {
		return v
	}
	return fallback
}

// effectiveMachine fills the gaps in a stored machine size.
func effectiveMachine(m models.Machine, env map[string]string) models.Machine {
	if m.CPU <= 0 {
		m.CPU = envFloat(env, "sandbox_cpu", 2)
	}
	if m.MemoryMB <= 0 {
		m.MemoryMB = int64(envFloat(env, "sandbox_memory_mb", 2048))
	}
	if m.DiskMB <= 0 {
		m.DiskMB = int64(envFloat(env, "sandbox_disk_mb", 4096))
	}
	// The reserve is a fraction of the sold size, with a floor, and never above it.
	if m.ReserveCPU <= 0 {
		m.ReserveCPU = math.Min(m.CPU, math.Max(0.25, m.CPU/8))
	}
	if m.ReserveMemoryMB <= 0 {
		m.ReserveMemoryMB = min(m.MemoryMB, max(512, m.MemoryMB/4))
	}
	// The ceiling is generous (the size computers had before reserves) and never below the sold size.
	if m.MaxCPU <= 0 {
		m.MaxCPU = 4
	}
	if m.MaxMemoryMB <= 0 {
		m.MaxMemoryMB = 8192
	}
	if m.ProviderIdleMin <= 0 {
		m.ProviderIdleMin = models.DefaultProviderIdleMin
	}
	if m.MaxLifetimeMin <= 0 {
		m.MaxLifetimeMin = models.DefaultMaxLifetimeMin
	}
	if m.CommandTimeoutSec <= 0 {
		m.CommandTimeoutSec = models.DefaultCommandTimeoutSec
	}
	m.MaxLifetimeMin = max(m.MaxLifetimeMin, m.ProviderIdleMin)
	m.MaxCPU = math.Max(m.MaxCPU, m.CPU)
	m.MaxMemoryMB = max(m.MaxMemoryMB, m.MemoryMB)
	m.ReserveCPU = math.Min(m.ReserveCPU, m.MaxCPU)
	m.ReserveMemoryMB = min(m.ReserveMemoryMB, m.MaxMemoryMB)
	return m
}

// parseMachine reads a stored or submitted machine size; a missing one is all
// automatic, and unknown fields or out-of-range sizes are refused.
func parseMachine(v any) (models.Machine, error) {
	if v == nil {
		return models.Machine{}, nil
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return models.Machine{}, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var m models.Machine
	if err := dec.Decode(&m); err != nil {
		return models.Machine{}, errs.InvalidArgument("invalid machine size: " + err.Error())
	}
	switch {
	case m.CPU < 0 || m.CPU > 64 || m.ReserveCPU < 0 || m.ReserveCPU > 64 || m.MaxCPU < 0 || m.MaxCPU > 64:
		return models.Machine{}, errs.InvalidArgument("CPU must be between 0 and 64 cores")
	case m.MemoryMB < 0 || m.MemoryMB > 262144 || m.ReserveMemoryMB < 0 || m.ReserveMemoryMB > 262144 || m.MaxMemoryMB < 0 || m.MaxMemoryMB > 262144:
		return models.Machine{}, errs.InvalidArgument("memory must be between 0 and 256 GB")
	case m.DiskMB < 0 || m.DiskMB > 2097152:
		return models.Machine{}, errs.InvalidArgument("disk must be between 0 and 2 TB")
	case m.ProviderIdleMin != 0 && (m.ProviderIdleMin < 5 || m.ProviderIdleMin > 1440):
		return models.Machine{}, errs.InvalidArgument("the provider idle limit must be between 5 minutes and 24 hours")
	case m.MaxLifetimeMin != 0 && (m.MaxLifetimeMin < 30 || m.MaxLifetimeMin > 1440):
		return models.Machine{}, errs.InvalidArgument("the longest a computer may run must be between 30 minutes and 24 hours")
	case m.ProviderIdleMin > 0 && m.MaxLifetimeMin > 0 && m.ProviderIdleMin > m.MaxLifetimeMin:
		return models.Machine{}, errs.InvalidArgument("the provider idle limit cannot be longer than the longest a computer may run")
	case m.CommandTimeoutSec != 0 && (m.CommandTimeoutSec < 10 || m.CommandTimeoutSec > 3600):
		return models.Machine{}, errs.InvalidArgument("the command limit must be between 10 seconds and 1 hour")
	case m.ReserveCPU > 0 && m.CPU > 0 && m.ReserveCPU > m.CPU:
		return models.Machine{}, errs.InvalidArgument("the idle reserve cannot be more than the size projects are sold at")
	case m.ReserveMemoryMB > 0 && m.MemoryMB > 0 && m.ReserveMemoryMB > m.MemoryMB:
		return models.Machine{}, errs.InvalidArgument("the idle reserve cannot be more than the size projects are sold at")
	}
	return m, nil
}

// AdminsSpace returns the id of the platform administrators' project, or "".
func (s *Service) AdminsSpace(ctx context.Context) (string, error) {
	row, e := s.Get(ctx)
	if e != nil {
		return "", e
	}
	id, _ := row.Values["admins_space"].(string)
	return id, nil
}

// SetAdminsSpace stores the platform administrators' project ("" clears it).
func (s *Service) SetAdminsSpace(ctx context.Context, id string) error {
	return s.save(ctx, map[string]any{"admins_space": id})
}

func (s *Service) Get(ctx context.Context) (*models.Settings, error) {
	var row models.Settings
	e := s.R.GetString(ctx, "platform_settings", s.id(), &row)
	if errs.CodeOf(e) == errs.CodeNotFound {
		return &models.Settings{ID: s.id(), Values: defaults()}, nil
	}
	return &row, e
}
func (s *Service) Instructions(ctx context.Context) (string, error) {
	row, e := s.Get(ctx)
	if e != nil {
		return "", e
	}
	text, _ := row.Values["universal_system_prompt"].(string)
	return strings.TrimSpace(text), nil
}
func (s *Service) getAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	row, e := s.Get(ctx)
	if e != nil {
		return nil, e
	}
	out := map[string]any{}
	for k, v := range row.Values {
		out[k] = v
	}
	if p, err := parsePricing(out["pricing"]); err == nil {
		out["pricing"] = p
	} else {
		out["pricing"] = models.DefaultPricing()
	}
	// The machine size is shown with every gap filled in.
	if stored, err := parseMachine(out["machine"]); err == nil {
		out["machine"] = effectiveMachine(stored, s.K.Env())
	} else {
		out["machine"] = effectiveMachine(models.Machine{}, s.K.Env())
	}
	for k := range out {
		if !allowedKeys[k] { // drop keys from older policy versions
			delete(out, k)
		}
	}
	text, _ := out["universal_system_prompt"].(string)
	out["universal_system_prompt_set"] = strings.TrimSpace(text) != ""
	if helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) != nil {
		delete(out, "universal_system_prompt")
	}
	out["version"] = row.Version
	return helper.JSON(out)
}
func (s *Service) updateAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in map[string]any
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if _, ok := in["admins_space"]; ok {
		// Choosing it also adds the administrators to the project.
		return nil, errs.InvalidArgument("set the admins space with spaces/admins_space_set")
	}
	if e := s.save(ctx, in); e != nil {
		return nil, e
	}
	return s.getAction(ctx, req)
}

// save validates and stores the given policy keys over the current ones.
func (s *Service) save(ctx context.Context, in map[string]any) error {
	row, e := s.Get(ctx)
	if e != nil {
		return e
	}
	old := row.Version
	for k, v := range in {
		if !allowedKeys[k] {
			return errs.InvalidArgument("unknown setting " + k)
		}
		switch k {
		case "universal_system_prompt":
			t, ok := v.(string)
			if !ok || len(t) > 64000 {
				return errs.InvalidArgument("invalid universal system prompt")
			}
		case "pricing":
			p, err := parsePricing(v)
			if err != nil {
				return err
			}
			v = p
		case "machine":
			m, err := parseMachine(v)
			if err != nil {
				return err
			}
			v = m
		case "admins_space":
			id, ok := v.(string)
			if !ok {
				return errs.InvalidArgument("invalid admins space")
			}
			if id = strings.TrimSpace(id); id != "" {
				if _, err := identity.Parse(id); err != nil {
					return errs.InvalidArgument("invalid admins space")
				}
			}
			v = id
		case "categories":
			list, ok := v.([]any)
			if !ok || len(list) == 0 || len(list) > 100 {
				return errs.InvalidArgument("categories must be a non-empty list")
			}
			for _, c := range list {
				if name, ok := c.(string); !ok || strings.TrimSpace(name) == "" || len(name) > 64 {
					return errs.InvalidArgument("invalid category")
				}
			}
		}
		row.Values[k] = v
	}
	raw, _ := json.Marshal(row.Values)
	if len(raw) > 128000 {
		return errs.InvalidArgument("settings too large")
	}
	row.Version++
	row.UpdatedAt = time.Now().UTC()
	if old == 0 {
		e = s.R.DB.Create(ctx, "platform_settings", row.ID, row)
	} else {
		var changed bool
		changed, e = s.R.CompareAndSwap(ctx, "platform_settings", row.ID, map[string]any{"version": old}, row)
		if e == nil && !changed {
			e = errs.Conflict("settings changed; reload before saving")
		}
	}
	return e
}
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "settings-ns", Version: "1.0.0", Provides: []string{"service/settings"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := &Service{K: d.Kernel, R: repo.New(d.Kernel)}
		return module.Instance{Service: s, Models: models.Models(), Actions: []api.Action{helper.Action{Namespace: "settings", Name: "get", Summary: "Read platform policy", Handler: s.getAction}, helper.Action{Namespace: "settings", Name: "update", Summary: "Update platform policy", Handler: s.updateAction}}}, nil
	})
}
