// Package admin implements the admin namespace: node administration, plugin
// load/unload, model/table management, wiring inspection & reprogramming,
// telemetry, logs and runtime workflows.
package admin

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/logs"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Workflow is a runtime-defined sequence of action calls.
type Workflow struct {
	ID    string         `json:"id"`
	Name  string         `json:"name"`
	Steps []WorkflowStep `json:"steps"`
}

// WorkflowStep calls one action; Args feed the action body.
type WorkflowStep struct {
	Action string `json:"action"` // "namespace/name"
	Args   any    `json:"args"`
}

// Service implements admin operations.
type Service struct {
	K     api.Runtime
	L     *logger.Logger
	Ring  *logs.Ring
	mu    sync.RWMutex
	flows map[string]*Workflow
}

// NewService builds the admin service.
func NewService(k api.Runtime, ring *logs.Ring, log *logger.Logger) *Service {
	return &Service{K: k, L: log.Named("admin"), Ring: ring, flows: map[string]*Workflow{}}
}

// BuildActions assembles the admin namespace actions.
func BuildActions(s *Service) []api.Action {
	actions := []api.Action{
		&pluginsBuildAction{s: s}, &pluginsStopAction{s: s}, &pluginsReplaceAction{s: s}, &pluginsListAction{s: s}, &pluginsLoadAction{s: s}, &pluginsUnloadAction{s: s},
		&pluginsUpdateAction{s: s}, &pluginsSetActiveAction{s: s}, &pluginsHealthAction{s: s},
		&actionsListAction{s: s},
		&modelsListAction{s: s}, &modelsRegisterAction{s: s}, &modelsUnregisterAction{s: s},
		&tablesListAction{s: s}, &tableGetAction{s: s}, &tableQueryAction{s: s},
		&wiringAction{s: s}, &telemetryAction{s: s}, &logsAction{s: s},
		&workflowsListAction{s: s}, &workflowCreateAction{s: s}, &workflowDeleteAction{s: s}, &workflowRunAction{s: s},
	}
	actions = append(actions, providerActions(s)...)
	actions = append(actions, productActions(s)...)
	for i, action := range actions {
		actions[i] = &adminGuard{s: s, action: action}
	}
	return actions
}

// requireAdmin accepts a user with the owner role at node level (handle gate).
func (s *Service) requireAdmin(req *api.ActionRequest) error {
	return helper.RequireNodeAdmin(context.Background(), repo.New(s.K), req, s.K.Env()["admin_handle"])
}

// --- plugins ---

type pluginsListAction struct{ s *Service }

func (a *pluginsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_list", Summary: "List all plugins and their states"}
}
func (a *pluginsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var out []map[string]any
	for _, e := range a.s.K.Registry().List() {
		out = append(out, map[string]any{
			"name": e.Plugin.Info().Name, "type": e.Plugin.Info().Type,
			"category": e.Plugin.Info().Category, "version": e.Plugin.Info().Version,
			"state": e.State.String(), "state_changed": e.StateChanged,
			"last_error": e.LastError, "provides": e.Plugin.Info().Provides,
		})
	}
	return helper.JSON(map[string]any{"plugins": out})
}

type pluginsLoadAction struct{ s *Service }

func (a *pluginsLoadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_load", Summary: "Load and start a plugin by name"}
}
func (a *pluginsLoadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		Name   string         `json:"name"`
		Path   string         `json:"path"`
		Config map[string]any `json:"config"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Path != "" {
		info, err := a.s.K.LoadPlugin(ctx, in.Path, in.Config)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"ok": true, "plugin": info.Name, "state": "started"})
	}

	if err := a.s.K.Init(in.Name); err != nil {
		return nil, err
	}
	if err := a.s.K.Start(in.Name); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "plugin": in.Name, "state": "started"})
}

type pluginsUnloadAction struct{ s *Service }

func (a *pluginsUnloadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_unload", Summary: "Stop and unload a plugin"}
}
func (a *pluginsUnloadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if a.s.asyncLifecycle(in.Name) {
		go func() {
			if err := a.s.K.Unload(in.Name); err != nil {
				a.s.L.Error("admin unload failed", "error", err)
			}
		}()
		return helper.JSON(map[string]any{"ok": true, "plugin": in.Name, "state": "unloading"})
	}
	if err := a.s.K.Unload(in.Name); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "plugin": in.Name, "state": "unloaded"})
}

type pluginsUpdateAction struct{ s *Service }

func (a *pluginsUpdateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_update", Summary: "Hot-update a plugin config"}
}
func (a *pluginsUpdateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		Name   string         `json:"name"`
		Config map[string]any `json:"config"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if a.s.asyncLifecycle(in.Name) {
		go func() {
			if err := a.s.K.Update(in.Name, in.Config); err != nil {
				a.s.L.Error("admin config update failed", "error", err)
			}
		}()
		return helper.JSON(map[string]any{"state": "updating"})
	}
	if err := a.s.K.Update(in.Name, in.Config); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "plugin": in.Name})
}

type pluginsSetActiveAction struct{ s *Service }

func (a *pluginsSetActiveAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_set_active", Summary: "Reprogram wiring: set the active adapter for a category"}
}
func (a *pluginsSetActiveAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		Category string `json:"category"` // database|cache|network|filesystem|vmm
		Plugin   string `json:"plugin"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.K.SetActive(api.Category(in.Category), in.Plugin); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "category": in.Category, "active": in.Plugin})
}

type pluginsHealthAction struct{ s *Service }

func (a *pluginsHealthAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_health", Summary: "Health of every plugin"}
}
func (a *pluginsHealthAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var out []map[string]any
	for _, e := range a.s.K.Registry().List() {
		h := e.Plugin.CheckHealth(ctx)
		out = append(out, map[string]any{"name": e.Plugin.Info().Name, "state": e.State.String(), "ok": h.OK, "message": h.Message})
	}
	return helper.JSON(map[string]any{"health": out})
}

// --- actions ---

type actionsListAction struct{ s *Service }

func (a *actionsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "actions_list", Summary: "List namespaces and registered actions"}
}
func (a *actionsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	router := a.s.K.Actions()
	namespaces := router.Namespaces()
	out := make([]map[string]any, 0, len(namespaces))
	for _, ns := range namespaces {
		out = append(out, map[string]any{"namespace": ns, "actions": router.List(ns)})
	}
	return helper.JSON(map[string]any{"namespaces": out})
}

// --- models & tables ---

type modelsListAction struct{ s *Service }

func (a *modelsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "models_list", Summary: "List database models"}
}
func (a *modelsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	return helper.JSON(map[string]any{"models": db.Models()})
}

type modelsRegisterAction struct{ s *Service }

func (a *modelsRegisterAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "models_register", Summary: "Register a new database model (schema)"}
}
func (a *modelsRegisterAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in database.Model
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	if err := db.RegisterModel(ctx, in); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "model": in.Name})
}

type modelsUnregisterAction struct{ s *Service }

func (a *modelsUnregisterAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "models_unregister", Summary: "Unregister a database model"}
}
func (a *modelsUnregisterAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		Model string `json:"model"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	if err := db.UnregisterModel(ctx, in.Model); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "model": in.Model})
}

type tablesListAction struct{ s *Service }

func (a *tablesListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "tables_list", Summary: "List records in a model/table"}
}
func (a *tablesListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Model  string `json:"model"`
		Limit  int    `json:"limit"`
		Offset int    `json:"offset"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	if in.Limit <= 0 || in.Limit > 500 {
		in.Limit = 100
	}
	var records []map[string]any
	if err := db.List(ctx, in.Model, database.Filter{Limit: in.Limit, Offset: in.Offset}, &records); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"model": in.Model, "count": len(records), "records": redactCredentials(records)})
}

type tableGetAction struct{ s *Service }

func (a *tableGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "table_get", Summary: "Get a single record by id"}
}
func (a *tableGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Model string `json:"model"`
		ID    string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	row := map[string]any{}
	if err := db.Get(ctx, in.Model, in.ID, &row); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"model": in.Model, "record": redactCredentials(row)})
}

type tableQueryAction struct{ s *Service }

func (a *tableQueryAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "table_query", Summary: "Run a native query against a model"}
}
func (a *tableQueryAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in database.Query
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	db := a.s.K.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database adapter active")
	}
	// Determine the model from meta or reject.
	model, _ := in.Meta["model"].(string)
	if model == "" {
		return nil, errs.InvalidArgument("meta.model required")
	}
	var records []map[string]any
	if err := db.Query(ctx, model, in, &records); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"records": redactCredentials(records)})
}

// --- wiring & telemetry & logs ---

type wiringAction struct{ s *Service }

func (a *wiringAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "wiring", Summary: "View adapter wiring and active adapters"}
}
func (a *wiringAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	cats := []api.Category{api.CategoryDatabase, api.CategoryCache, api.CategoryNetwork, api.CategoryFilesystem, api.CategoryVMM}
	active := map[string]any{}
	for _, c := range cats {
		name := a.s.K.Active(c)
		if name == "" {
			active[string(c)] = nil
		} else {
			active[string(c)] = name
		}
	}
	return helper.JSON(map[string]any{"active": active, "node_id": a.s.K.NodeID().String()})
}

type telemetryAction struct{ s *Service }

func (a *telemetryAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "telemetry", Summary: "Node telemetry snapshot"}
}
func (a *telemetryAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var healths []map[string]any
	for _, e := range a.s.K.Registry().List() {
		h := e.Plugin.CheckHealth(ctx)
		healths = append(healths, map[string]any{"name": e.Plugin.Info().Name, "ok": h.OK, "message": h.Message})
	}
	namespaces := a.s.K.Actions().Namespaces()
	return helper.JSON(map[string]any{
		"node_id": a.s.K.NodeID().String(), "plugins": healths,
		"namespaces": namespaces, "time": time.Now().UTC(),
	})
}

type logsAction struct{ s *Service }

func (a *logsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "logs", Summary: "Recent system logs"}
}
func (a *logsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Limit int `json:"limit"`
	}
	_ = helper.Decode(req, &in)
	if in.Limit <= 0 || in.Limit > 2000 {
		in.Limit = 200
	}
	return helper.JSON(map[string]any{"logs": a.s.Ring.Recent(in.Limit)})
}

// --- workflows ---

type workflowsListAction struct{ s *Service }

func (a *workflowsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "workflows_list", Summary: "List runtime workflows"}
}
func (a *workflowsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	a.s.mu.RLock()
	defer a.s.mu.RUnlock()
	out := make([]*Workflow, 0, len(a.s.flows))
	for _, w := range a.s.flows {
		out = append(out, w)
	}
	return helper.JSON(map[string]any{"workflows": out})
}

type workflowCreateAction struct{ s *Service }

func (a *workflowCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "workflow_create", Summary: "Define a workflow of action calls"}
}
func (a *workflowCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in Workflow
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Name == "" || len(in.Steps) == 0 {
		return nil, errs.InvalidArgument("name and steps required")
	}
	in.ID = workflowID()
	a.s.mu.Lock()
	a.s.flows[in.ID] = &in
	a.s.mu.Unlock()
	return helper.JSON(map[string]any{"workflow_id": in.ID})
}

type workflowDeleteAction struct{ s *Service }

func (a *workflowDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "workflow_delete", Summary: "Delete a workflow"}
}
func (a *workflowDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	a.s.mu.Lock()
	delete(a.s.flows, in.ID)
	a.s.mu.Unlock()
	return helper.JSON(map[string]any{"ok": true})
}

type workflowRunAction struct{ s *Service }

func (a *workflowRunAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "workflow_run", Summary: "Execute a workflow"}
}
func (a *workflowRunAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		ID   string `json:"id"`
		Args any    `json:"args"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	a.s.mu.RLock()
	flow, ok := a.s.flows[in.ID]
	a.s.mu.RUnlock()
	if !ok {
		return nil, errs.NotFound("workflow " + in.ID)
	}
	var results []map[string]any
	last := in.Args
	for i, step := range flow.Steps {
		ns, name, ok2 := split(step.Action)
		if !ok2 {
			return nil, errs.InvalidArgument("malformed step action " + step.Action)
		}
		body, _ := json.Marshal(step.Args)
		if last != nil && step.Args == nil {
			body, _ = json.Marshal(last)
		}
		resp, err := a.s.K.Actions().Dispatch(ctx, ns, name, &api.ActionRequest{
			Caller: req.Caller, Origin: a.s.K.NodeID(), Body: body,
		})
		if err != nil {
			return nil, err
		}
		results = append(results, map[string]any{"step": i, "action": step.Action, "status": resp.Status})
		last = resp.Body
	}
	return helper.JSON(map[string]any{"workflow": flow.ID, "results": results})
}

func workflowID() string {
	id, err := identity.New(0)
	if err != nil {
		return "wf"
	}
	return id.EntityString()
}

func split(ref string) (string, string, bool) {
	for i := 0; i < len(ref); i++ {
		if ref[i] == '/' {
			return ref[:i], ref[i+1:], true
		}
	}
	return "", "", false
}

type adminGuard struct {
	s      *Service
	action api.Action
}

func (a *adminGuard) Meta() api.ActionMeta { return a.action.Meta() }
func (a *adminGuard) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	return a.action.Handle(ctx, req)
}
