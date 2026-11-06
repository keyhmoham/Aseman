package developer

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/developer/workflow"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// The workflow installer: one JSON document that brings up a whole product
// through the platform's actions, in order (see the workflow package and
// docs/WORKFLOWS.md). It runs from the console as the person, and on the
// developer host as the person behind the key — never with more than that
// person, or that key, may do on its own.

// MaxActiveWorkflows is how many runs one organization may have going at once.
const MaxActiveWorkflows = 3

// A running workflow's node saves a heartbeat this often, and looks for a
// cancel another node asked for; a run whose heartbeat is older than
// workflowStale is taken for interrupted (its node stopped).
var (
	workflowSyncWait    = 9 * time.Minute
	workflowSyncWaitMax = 25 * time.Minute
	workflowHeartbeat   = 20 * time.Second
	workflowStale       = 2 * time.Minute
)

// WorkflowRequest asks to validate, plan or run a workflow.
type WorkflowRequest struct {
	// Workflow is the document (an object, or JSON text).
	Workflow json.RawMessage   `json:"workflow"`
	Inputs   map[string]any    `json:"inputs,omitempty"`
	Secrets  map[string]string `json:"secrets,omitempty"`
	// Mode: run (default), plan or validate.
	Mode  string `json:"mode,omitempty"`
	Async bool   `json:"async,omitempty"`
	// WaitSeconds bounds how long a synchronous call waits before it answers
	// with the run still going (default 540, at most 1500: under the edge's
	// and the web app's proxy timeouts).
	WaitSeconds int `json:"wait_seconds,omitempty"`
	// ResumeFrom reuses the outputs of the top-level steps a previous run of
	// the organization finished; the workflow defaults to that run's.
	ResumeFrom string `json:"resume_from,omitempty"`
}

// WorkflowRunView is a run as the API shows it.
type WorkflowRunView struct {
	ID          string           `json:"id"`
	Object      string           `json:"object"`
	Org         string           `json:"org"`
	Key         string           `json:"key,omitempty"`
	CreatedBy   string           `json:"created_by,omitempty"`
	Name        string           `json:"name"`
	Version     string           `json:"version,omitempty"`
	Mode        string           `json:"mode"`
	Status      string           `json:"status"`
	Error       string           `json:"error,omitempty"`
	ResumedFrom string           `json:"resumed_from,omitempty"`
	StartedAt   string           `json:"started_at"`
	FinishedAt  string           `json:"finished_at,omitempty"`
	Report      *workflow.Report `json:"report,omitempty"`
}

// wfActor is who a workflow acts as and where.
type wfActor struct {
	person identity.ID
	handle string
	// org is the organization developer.* steps default to, and the run's
	// owner; orgRef is how the console names it ("personal" or an id).
	org    identity.ID
	orgRef string
	// key is set on the developer host: the run is held to its permissions.
	key *Principal
}

// keyDeveloperActions are the developer console actions a key's workflow may
// use, with the key permission each needs (read for reading ones, write for
// the rest). Keys, members, the organization itself and its money stay with
// the signed-in console.
var keyDeveloperActions = map[string]string{
	"models": "models", "platform_catalog": "platform",
	"platforms_list": "platform", "platform_get": "platform", "platform_create": "platform", "platform_rename": "platform", "platform_stats": "platform",
	"platform_users": "platform", "platform_frontend_apps": "platform", "platform_frontend_publish": "platform",
	"platform_frontend_unpublish": "platform", "platform_frontend": "platform",
	"settings_get": "usage", "wallet_get": "usage", "usage_report": "usage", "logs_list": "usage",
	"computers_options": "computers", "computers_list": "computers", "computer_create": "computers",
	"computer_status": "computers", "computer_delete": "computers", "computer_exec": "computers",
	"storage_info": "files", "files_list": "files", "file_upload": "files", "file_read": "files", "file_delete": "files",
}

func readOnlyAction(name string) bool {
	for _, suffix := range []string{"_get", "_list", "_options", "_stats", "_users", "_info", "_read", "_report", "_catalog", "_apps"} {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return name == "models" || name == "platform_frontend"
}

// workflowPolicy says whether an actor's workflow may call an action.
func (s *Service) workflowPolicy(a wfActor, ns, action string) (bool, string) {
	if ns == "developer" {
		if strings.HasPrefix(action, "workflow") {
			return false, "a workflow cannot start workflows"
		}
		if a.key != nil {
			res, ok := keyDeveloperActions[action]
			if !ok {
				return false, "on the developer API a workflow cannot use developer." + action + " (keys, members, money and the organization itself are managed from the console)"
			}
			lvl := LevelWrite
			if readOnlyAction(action) {
				lvl = LevelRead
			}
			if err := a.key.Need(res, lvl); err != nil {
				return false, err.Error()
			}
		}
		return true, ""
	}
	if !platformAllowed(ns, action) {
		return false, "node administration is not available to workflows"
	}
	return true, ""
}

// wfCatalog checks a workflow's actions against what is registered and what
// the actor may call.
type wfCatalog struct {
	s *Service
	a wfActor
}

func (c wfCatalog) ActionExists(name string) (bool, string) {
	ns, action, _ := strings.Cut(name, ".")
	if ok, why := c.s.workflowPolicy(c.a, ns, action); !ok {
		return false, why
	}
	router := c.s.K.Actions()
	if router == nil {
		return true, ""
	}
	for _, m := range router.List(ns) {
		if m.Name == action {
			return true, ""
		}
	}
	return false, "no such action (see GET /v1/platform for the collection)"
}

// wfCaller runs a workflow's steps on the node.
type wfCaller struct {
	s     *Service
	a     wfActor
	runID string
	stamp bool
	// platformRef is the platform the run stamps (options.platform): its id
	// or slug. Empty: the key's, else the organization's only one.
	platformRef string
}

// platformScopedAction are the developer actions that act on one platform
// of the organization (named by "platform").
var platformScopedAction = map[string]bool{
	"platform_get": true, "platform_rename": true, "platform_delete": true, "platform_stats": true,
	"platform_users": true, "platform_frontend_publish": true, "platform_frontend_unpublish": true,
}

// boundPlatform is the id of the platform the run's key is bound to ("": none).
func (c *wfCaller) boundPlatform() string {
	if c.a.key == nil {
		return ""
	}
	return c.a.key.Key.PlatformID
}

// platform is the platform what the run makes joins (nil: main Aseman).
func (c *wfCaller) platform(ctx context.Context) (*models.Platform, error) {
	if c.platformRef == "" {
		if c.a.key != nil {
			return c.s.KeyPlatform(ctx, c.a.key.Key)
		}
		return c.s.OrgPlatform(ctx, c.a.org, "")
	}
	p, err := c.s.OrgPlatform(ctx, c.a.org, c.platformRef)
	if err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			// Not made yet: a later step may create it.
			return nil, nil
		}
		return nil, err
	}
	if bound := c.boundPlatform(); bound != "" && p != nil && bound != p.ID.String() {
		return nil, errs.Permission("a key's workflow works on the platform the key is bound to")
	}
	return p, nil
}

func (c *wfCaller) Call(ctx context.Context, name string, with map[string]any) (any, error) {
	ns, action, _ := strings.Cut(name, ".")
	if ok, why := c.s.workflowPolicy(c.a, ns, action); !ok {
		return nil, errs.Permission(why)
	}
	if ns == "developer" {
		given := strings.TrimSpace(ToStringAny(with["org"]))
		if given == "" {
			with["org"] = c.a.orgRef
		} else if c.a.key != nil && given != c.a.orgRef && given != c.a.org.String() {
			return nil, errs.Permission("a key's workflow works in the key's own organization")
		}
		// A key bound to a platform manages that platform only.
		if bound := c.boundPlatform(); bound != "" && platformScopedAction[action] {
			given := strings.TrimSpace(ToStringAny(with["platform"]))
			if given == "" {
				with["platform"] = bound
			} else if p, err := c.s.PlatformByRef(ctx, given); err != nil || p.ID.String() != bound {
				return nil, errs.Permission("a key's workflow works on the platform the key is bound to")
			}
		}
	}
	router := c.s.K.Actions()
	if router == nil {
		return nil, errs.New(errs.CodeUnavailable, "the platform is unavailable right now")
	}
	platformID := ""
	if c.stamp && ns != "developer" {
		// Looked up each time: a step may have just created the platform.
		p, err := c.platform(ctx)
		if err != nil {
			return nil, err
		}
		if p != nil {
			platformID = p.ID.String()
			ctx = helper.WithPlatform(ctx, platformID)
		}
	}
	body, err := json.Marshal(with)
	if err != nil {
		return nil, errs.InvalidArgument("the request cannot be sent as JSON")
	}
	meta := map[string]any{"handle": c.a.handle, "developer_org": c.a.org.String(), "platform_id": platformID, "workflow_run": c.runID}
	if c.a.key != nil {
		meta["developer_key"] = c.a.key.Key.ID.String()
	}
	// Acting as the person, as every in-process caller does: what the action
	// starts on their behalf (a computer woken, time billed) is theirs.
	ctx = helper.WithActor(ctx, c.a.person)
	resp, err := router.Dispatch(ctx, ns, action, &api.ActionRequest{Caller: api.Caller{ID: c.a.person, Kind: "user"}, Origin: c.s.K.NodeID(), Body: body, Meta: meta})
	if err != nil {
		return nil, err
	}
	if resp == nil || len(resp.Body) == 0 {
		return map[string]any{"ok": true}, nil
	}
	var out any
	if json.Unmarshal(resp.Body, &out) != nil {
		return map[string]any{"raw": string(resp.Body)}, nil
	}
	if resp.Status >= 400 {
		return nil, errs.New(errs.CodeInternal, clip(string(resp.Body), 500))
	}
	return out, nil
}

// ToStringAny renders a request value as text.
func ToStringAny(v any) string { return workflow.ToString(v) }

var wfModelTypes = map[string]string{
	"chat": TypeLanguage, "embeddings": TypeEmbedding, "image": TypeImage, "speech": TypeSpeech,
	"transcription": TypeTranscription, "rerank": TypeRerank, "decision": TypeDecision,
}

func (c *wfCaller) Model(ctx context.Context, typ string, body map[string]any) (any, error) {
	t, ok := wfModelTypes[typ]
	if !ok {
		return nil, errs.InvalidArgument("unknown model type " + typ)
	}
	call, bad := parseCall(t, body)
	if bad != "" {
		return nil, errs.InvalidArgument(bad)
	}
	call.Stream = false
	call.Org = c.a.org
	if c.a.key != nil {
		call.Principal, call.KeyID, call.KeyName = c.a.key, c.a.key.Key.ID.String(), c.a.key.Key.Name
	} else {
		sc, err := c.s.Scope(ctx, c.a.person, c.a.orgRef)
		if err != nil {
			return nil, err
		}
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		call.KeyID, call.KeyName = "workflow", "Workflow"
	}
	res := c.s.Execute(ctx, call)
	if res.Status >= 300 {
		var e struct {
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(res.Body, &e)
		msg := firstText(e.Error.Message, "the model call failed (HTTP "+strconv.Itoa(res.Status)+")")
		switch {
		case res.Status == http.StatusPaymentRequired:
			return nil, errs.New(errs.CodeFinance, msg)
		case res.Status == 403:
			return nil, errs.Permission(msg)
		case res.Status == 400 || res.Status == 404:
			return nil, errs.InvalidArgument(msg)
		}
		return nil, errs.New(errs.CodeUnavailable, msg)
	}
	if t == TypeSpeech {
		return map[string]any{"content_type": res.Header["Content-Type"], "audio_base64": base64.StdEncoding.EncodeToString(res.Body),
			"model": res.Model, "provider": res.Provider, "cost": usd(float64(res.Cost))}, nil
	}
	var out map[string]any
	if err := json.Unmarshal(res.Body, &out); err != nil {
		return map[string]any{"raw": string(res.Body)}, nil
	}
	if t == TypeLanguage {
		if choices, _ := out["choices"].([]any); len(choices) > 0 {
			if ch, _ := choices[0].(map[string]any); ch != nil {
				if msg, _ := ch["message"].(map[string]any); msg != nil {
					out["text"] = msg["content"]
				}
			}
		}
	}
	out["provider_used"], out["cost_usd"] = res.Provider, usd(float64(res.Cost))
	return out, nil
}

func firstText(a ...string) string {
	for _, s := range a {
		if strings.TrimSpace(s) != "" {
			return s
		}
	}
	return ""
}

// workflowErrorCode classifies an error for retries and the report.
func workflowErrorCode(err error) string {
	var ae *AuthError
	if asAuth(err, &ae) {
		switch ae.Status {
		case 401:
			return "unauthenticated"
		case 402:
			return "finance"
		case 403:
			return "permission"
		case 404:
			return "not_found"
		case 409:
			return "conflict"
		case 429:
			return "rate_limited"
		case 400:
			return "invalid_argument"
		}
		return "unavailable"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	switch errs.CodeOf(err) {
	case errs.CodeNotFound:
		return "not_found"
	case errs.CodeAlreadyExists:
		return "already_exists"
	case errs.CodeInvalidArgument:
		return "invalid_argument"
	case errs.CodeUnauthenticated:
		return "unauthenticated"
	case errs.CodePermission:
		return "permission"
	case errs.CodeConflict:
		return "conflict"
	case errs.CodeUnavailable, errs.CodeVMM, errs.CodeFederation:
		return "unavailable"
	case errs.CodeFinance, errs.CodeBudgetExhausted:
		return "finance"
	}
	return "internal"
}

// decodeWorkflow reads the document, given as an object or as JSON text.
func decodeWorkflow(raw json.RawMessage) (*workflow.Workflow, []byte, error) {
	raw = json.RawMessage(strings.TrimSpace(string(raw)))
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil, errs.InvalidArgument("`workflow` is required: the workflow document")
	}
	if raw[0] == '"' {
		var text string
		if err := json.Unmarshal(raw, &text); err != nil {
			return nil, nil, errs.InvalidArgument("`workflow` must be an object or JSON text")
		}
		raw = json.RawMessage(text)
	}
	wf, err := workflow.Decode(raw)
	if err != nil {
		return nil, nil, errs.InvalidArgument(err.Error())
	}
	return wf, raw, nil
}

// ValidateWorkflow checks a document without running anything.
func (s *Service) ValidateWorkflow(ctx context.Context, a wfActor, raw json.RawMessage) (map[string]any, error) {
	wf, _, err := decodeWorkflow(raw)
	if err != nil {
		msg := err.Error()
		var coded *errs.Error
		if errors.As(err, &coded) {
			msg = coded.Message
		}
		return map[string]any{"valid": false, "issues": []workflow.Issue{{Path: "", Message: msg, Severity: "error"}}}, nil
	}
	issues := workflow.Validate(wf, wfCatalog{s: s, a: a})
	if issues == nil {
		issues = []workflow.Issue{}
	}
	steps := 0
	var count func([]*workflow.Step)
	count = func(list []*workflow.Step) {
		for _, st := range list {
			if st != nil {
				steps++
				count(st.Steps)
			}
		}
	}
	count(wf.Steps)
	return map[string]any{"valid": !workflow.HasErrors(issues), "issues": issues, "name": wf.Name, "version": wf.Version,
		"steps": steps, "inputs": wf.Inputs, "secrets": wf.Secrets, "assets": len(wf.Assets)}, nil
}

func (s *Service) wfActive() (*sync.Mutex, map[string]context.CancelFunc) {
	s.wfMu.Lock()
	if s.wfRuns == nil {
		s.wfRuns = map[string]context.CancelFunc{}
	}
	s.wfMu.Unlock()
	return &s.wfMu, s.wfRuns
}

// StartWorkflow plans or runs a workflow and records it. A synchronous call
// answers when the run is over; an asynchronous one at once, with the run
// still going.
func (s *Service) StartWorkflow(ctx context.Context, a wfActor, in WorkflowRequest) (*WorkflowRunView, error) {
	mode := strings.ToLower(strings.TrimSpace(in.Mode))
	if mode == "" {
		mode = workflow.ModeRun
	}
	if mode != workflow.ModeRun && mode != workflow.ModePlan {
		return nil, errs.InvalidArgument("mode is run, plan or validate")
	}
	var resume map[string]any
	var prev *models.WorkflowRun
	if in.ResumeFrom != "" {
		p, err := s.loadWorkflowRun(ctx, a.org, in.ResumeFrom)
		if err != nil {
			return nil, err
		}
		prev = p
		resume = resumable(p)
		if len(in.Workflow) == 0 {
			in.Workflow = json.RawMessage(p.Definition)
		}
		if in.Inputs == nil {
			// The inputs it ran with (sensitive ones were not kept).
			var rep workflow.Report
			if json.Unmarshal([]byte(p.Report), &rep) == nil {
				in.Inputs = map[string]any{}
				for k, v := range rep.Inputs {
					if !workflow.HasRedacted(v) {
						in.Inputs[k] = v
					}
				}
			}
		}
	}
	wf, raw, err := decodeWorkflow(in.Workflow)
	if err != nil {
		return nil, err
	}
	if a.key == nil && wf.Options.Org != "" {
		// The document's organization, when the console was not told one.
		if a.orgRef == PersonalOrg && wf.Options.Org != PersonalOrg {
			sc, err := s.Scope(ctx, a.person, wf.Options.Org)
			if err != nil {
				return nil, err
			}
			a.org, a.orgRef = sc.Org, wf.Options.Org
		}
	}
	running, err := s.activeWorkflows(ctx, a.org)
	if err != nil {
		return nil, err
	}
	if running >= MaxActiveWorkflows {
		return nil, errs.Conflict("this organization already has " + strconv.Itoa(running) + " workflows running; wait for one to finish or cancel it")
	}
	mu, active := s.wfActive()

	id, err := s.newID()
	if err != nil {
		return nil, err
	}
	now := s.now()
	rec := models.WorkflowRun{OrgID: a.org, CreatedBy: a.person, Name: wf.Name, Version: wf.Version, Mode: mode, Status: workflow.StatusRunning,
		Definition: string(raw), StartedAt: now}
	rec.ID, rec.CreatedAt, rec.UpdatedAt = id, now, now
	if a.key != nil {
		rec.KeyID = a.key.Key.ID.String()
	}
	if prev != nil {
		rec.ResumedFrom = prev.ID.String()
	}
	if err := s.R.CreateID(ctx, "dev_workflow_runs", id, rec); err != nil {
		return nil, err
	}

	runKey := a.org.String() + "/" + id.String()
	runCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	mu.Lock()
	active[runKey] = cancel
	mu.Unlock()

	caller := &wfCaller{s: s, a: a, runID: id.String(), stamp: a.key != nil || wf.Options.StampPlatform || wf.Options.Platform != "",
		platformRef: strings.TrimSpace(wf.Options.Platform)}
	var saveMu sync.Mutex
	lastSave := time.Time{}
	var lastRep *workflow.Report
	// save writes the run's progress; heartbeat-only saves (rep nil) just
	// say the run is alive.
	save := func(rep *workflow.Report, final, force bool) {
		saveMu.Lock()
		defer saveMu.Unlock()
		if rep != nil {
			lastRep = rep
		}
		if !final && !force && s.now().Sub(lastSave) < 2*time.Second {
			return
		}
		lastSave = s.now()
		r := rec
		if lastRep != nil {
			b, _ := json.Marshal(lastRep)
			r.Report = string(b)
		}
		r.UpdatedAt = s.now()
		if final && lastRep != nil {
			r.Status, r.Error, r.FinishedAt = lastRep.Status, lastRep.Error, lastRep.FinishedAt
		}
		if err := s.R.Update(context.WithoutCancel(ctx), "dev_workflow_runs", id, r); err != nil {
			s.L.Warn("developer: saving a workflow run", "run", id.String(), "error", err)
		}
		rec = r
	}
	heartbeat := workflowHeartbeat
	exec := func() *workflow.Report {
		done := make(chan struct{})
		defer func() {
			close(done)
			mu.Lock()
			delete(active, runKey)
			mu.Unlock()
			cancel()
			_ = s.R.Delete(context.WithoutCancel(ctx), "dev_workflow_cancels", id)
		}()
		go func() {
			tick := time.NewTicker(heartbeat)
			defer tick.Stop()
			for {
				select {
				case <-done:
					return
				case <-tick.C:
					var asked models.WorkflowCancel
					if s.R.Get(context.WithoutCancel(ctx), "dev_workflow_cancels", id, &asked) == nil {
						cancel()
					}
					save(nil, false, true)
				}
			}
		}()
		rep := workflow.Run(runCtx, wf, caller, wfCatalog{s: s, a: a}, workflow.Options{
			Mode: mode, Inputs: in.Inputs, Secrets: in.Secrets, Resume: resume, ErrorCode: workflowErrorCode,
			Now: s.now, Run: map[string]any{"id": id.String(), "org": a.org.String(), "actor": a.handle, "via": map[bool]string{true: "api_key", false: "console"}[a.key != nil]},
			OnProgress: func(rep *workflow.Report) { save(rep, false, false) },
		})
		save(rep, true, true)
		return rep
	}
	view := s.workflowView(ctx, rec, false)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		defer func() {
			if p := recover(); p != nil {
				s.L.Error("developer: a workflow run panicked", "run", id.String(), "panic", p)
			}
		}()
		exec()
	}()
	if in.Async {
		return &view, nil
	}
	wait := workflowSyncWait
	if in.WaitSeconds > 0 {
		wait = min(time.Duration(in.WaitSeconds)*time.Second, workflowSyncWaitMax)
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-finished:
		var done models.WorkflowRun
		if err := s.R.Get(ctx, "dev_workflow_runs", id, &done); err != nil {
			return nil, err
		}
		view = s.workflowView(ctx, done, true)
	case <-timer.C:
		// Still going: the caller follows it with GET …/runs/{id}.
	case <-ctx.Done():
		// The caller left; the run goes on.
	}
	return &view, nil
}

// activeWorkflows counts an organization's runs that are alive on any node.
func (s *Service) activeWorkflows(ctx context.Context, org identity.ID) (int, error) {
	n, err := s.R.Count(ctx, "dev_workflow_runs", database.Filter{
		Equal:       map[string]any{"org_id": org.String(), "status": workflow.StatusRunning},
		GreaterThan: map[string]any{"updated_at": s.now().Add(-workflowStale)},
	})
	return int(n), err
}

// resumable is what a previous run finished: its top-level steps' outputs.
func resumable(p *models.WorkflowRun) map[string]any {
	var rep workflow.Report
	if json.Unmarshal([]byte(p.Report), &rep) != nil {
		return nil
	}
	out := map[string]any{}
	for _, st := range rep.Steps {
		// A step whose stored outputs had secrets hidden runs again: its
		// redacted outputs are not what later steps need.
		if st.ID != "" && st.Path == st.ID && (st.Status == workflow.StatusSucceeded || st.Status == workflow.StatusReused) &&
			st.Request != "(sensitive)" && !workflow.HasRedacted(st.Outputs) {
			out[st.ID] = st.Outputs
		}
	}
	return out
}

func (s *Service) loadWorkflowRun(ctx context.Context, org identity.ID, ref string) (*models.WorkflowRun, error) {
	id, err := identity.Parse(strings.TrimPrefix(strings.TrimSpace(ref), "wfr_"))
	var rec models.WorkflowRun
	if err == nil {
		err = s.R.Get(ctx, "dev_workflow_runs", id, &rec)
	}
	if err != nil || rec.OrgID != org {
		return nil, errs.NotFound("workflow run")
	}
	return &rec, nil
}

func (s *Service) workflowView(ctx context.Context, rec models.WorkflowRun, full bool) WorkflowRunView {
	status := rec.Status
	if status == workflow.StatusRunning && !s.workflowLive(rec) && s.now().Sub(rec.UpdatedAt) > workflowStale {
		status = "interrupted"
	}
	v := WorkflowRunView{ID: rec.ID.String(), Object: "workflow.run", Org: rec.OrgID.String(), Key: rec.KeyID, CreatedBy: s.handleOf(ctx, rec.CreatedBy),
		Name: rec.Name, Version: rec.Version, Mode: rec.Mode, Status: status, Error: rec.Error, ResumedFrom: rec.ResumedFrom,
		StartedAt: stamp(rec.StartedAt), FinishedAt: stamp(rec.FinishedAt)}
	if full && rec.Report != "" {
		var rep workflow.Report
		if json.Unmarshal([]byte(rec.Report), &rep) == nil {
			v.Report = &rep
		}
	}
	return v
}

func (s *Service) workflowLive(rec models.WorkflowRun) bool {
	mu, active := s.wfActive()
	mu.Lock()
	defer mu.Unlock()
	_, ok := active[rec.OrgID.String()+"/"+rec.ID.String()]
	return ok
}

// WorkflowRuns lists an organization's recent runs, newest first.
func (s *Service) WorkflowRuns(ctx context.Context, org identity.ID, limit int) ([]WorkflowRunView, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var list []models.WorkflowRun
	if err := s.R.List(ctx, "dev_workflow_runs", database.Filter{Equal: map[string]any{"org_id": org.String()}, OrderBy: "created_at", Asc: false, Limit: limit}, &list); err != nil {
		return nil, err
	}
	out := make([]WorkflowRunView, 0, len(list))
	for _, r := range list {
		out = append(out, s.workflowView(ctx, r, false))
	}
	return out, nil
}

// WorkflowRun is one run with its report.
func (s *Service) WorkflowRun(ctx context.Context, org identity.ID, ref string) (*WorkflowRunView, error) {
	rec, err := s.loadWorkflowRun(ctx, org, ref)
	if err != nil {
		return nil, err
	}
	v := s.workflowView(ctx, *rec, true)
	return &v, nil
}

// CancelWorkflow stops a running workflow; what it already did stays (or is
// rolled back, when the workflow asks for that).
func (s *Service) CancelWorkflow(ctx context.Context, org, by identity.ID, ref string) (*WorkflowRunView, error) {
	rec, err := s.loadWorkflowRun(ctx, org, ref)
	if err != nil {
		return nil, err
	}
	mu, active := s.wfActive()
	mu.Lock()
	cancel, live := active[org.String()+"/"+rec.ID.String()]
	mu.Unlock()
	asked := false
	switch {
	case live:
		cancel()
	case rec.Status == workflow.StatusRunning && s.now().Sub(rec.UpdatedAt) <= workflowStale:
		// Another node runs it: ask it, through the store, on its heartbeat.
		c := models.WorkflowCancel{OrgID: org, By: by}
		c.ID, c.CreatedAt, c.UpdatedAt = rec.ID, s.now(), s.now()
		if err := s.R.EnsureCreated(ctx, "dev_workflow_cancels", rec.ID, c); err != nil {
			return nil, err
		}
		asked = true
	case rec.Status == workflow.StatusRunning:
		// Its node stopped: nothing is running it any more.
		rec.Status, rec.Error, rec.FinishedAt, rec.UpdatedAt = workflow.StatusCancelled, "cancelled after the run was interrupted", s.now(), s.now()
		if err := s.R.Update(ctx, "dev_workflow_runs", rec.ID, rec); err != nil {
			return nil, err
		}
	default:
		return nil, errs.Conflict("this run is already " + rec.Status)
	}
	v := s.workflowView(ctx, *rec, false)
	if live || asked {
		v.Status = "cancelling"
	}
	return &v, nil
}

// WorkflowReference is the format's reference: step kinds, built-in
// resources, functions and limits.
func WorkflowReference() map[string]any {
	presets := map[string]any{}
	for name, p := range workflow.Presets {
		presets[name] = p
	}
	return map[string]any{
		"object":    "workflow.reference",
		"format":    workflow.FormatVersion,
		"docs":      "docs/WORKFLOWS.md",
		"kinds":     workflowKinds,
		"presets":   presets,
		"functions": workflow.Functions(),
		"context": map[string]string{
			"inputs": "the run's inputs, defaults filled in", "vars": "workflow vars (vars, set and export)", "secrets": "the run's secrets (never stored)",
			"steps.<id>": "{status, outputs, error, id, operation}", "assets": "{name, size, mime} of each asset", "run": "{id, org, actor, via, mode, workflow, version}",
			"item / index / loop": "inside for_each (or the names as/index_as give)", "params": "inside a template", "result": "in outputs, export, collect, until and compensate",
			"error": "inside on_error", "failure": "inside on_failure", "outcome": "inside finally", "attempt": "the attempt number, under retry",
		},
		"limits": map[string]any{"document_mb": workflow.MaxDocumentBytes >> 20, "steps": workflow.MaxSteps, "depth": workflow.MaxDepth,
			"concurrency": workflow.MaxConcurrency, "attempts": workflow.MaxAttempts, "timeout_default": workflow.DefaultRunTimeout.String(),
			"timeout_max": workflow.MaxRunTimeout.String(), "active_runs_per_org": MaxActiveWorkflows},
	}
}

var workflowKinds = map[string]string{
	"action":  `{"action": "namespace.action", "with": {...}} — any platform action (GET /v1/platform), and developer.* console actions`,
	"upsert":  `{"upsert": {"resource": "space|room|agent|app|theme|space_bot|proxy|org|member|platform|key|computer", "match": {...}, "with": {...}, "mode": "upsert|ensure|update|create"}} — or "define" your own find/create/update/delete`,
	"model":   `{"model": {"type": "chat|embeddings|image|speech|transcription|rerank|decision", "body": {"model": "…", …}}} — routed, billed and logged like the API`,
	"sandbox": `{"sandbox": {"space": "…", "start": true, "root": "apps/x", "clean": true, "files": {...}, "assets": "prefix/", "exec": [...], "env": {...}, "proxy": {"port": 8000, "start": "…"}}} — install, build and serve software on a space's computer`,
	"wait":    `{"wait": {"action": "…", "with": {...}, "until": "result.status == 'running'", "interval": "5s", "timeout": "10m"}}`,
	"set":     `{"set": {"name": value}} — workflow vars`,
	"assert":  `{"assert": "expr"} or [{"that": "expr", "message": "…"}]`,
	"log":     `{"log": "text"}`,
	"sleep":   `{"sleep": "10s"}`,
	"fail":    `{"fail": "message"}`,
	"steps":   `{"steps": [...], "parallel": false} — a group`,
	"use":     `{"use": "template", "with": {...params}} — a template from "templates"`,
	"common":  `id, name, if, for_each (+as, index_as, concurrency, collect), retry {attempts, delay, backoff, max_delay, on}, timeout, continue_on_error, on_error [...], compensate {step}, outputs, export, sensitive, plan ("run"|"skip")`,
}

// workflowGuide is the authoring guide as the API answers it.
func workflowGuide() map[string]any {
	return map[string]any{"object": "workflow.guide", "format": "markdown", "content": workflow.Guide}
}

// ---- console actions ----

// workflowActions are the console's workflow actions, signed in as the person.
func (s *Service) workflowActions(scoped func(name, summary string, fn func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error))) {
	actor := func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) wfActor {
		ref := PersonalOrg
		if !sc.Personal {
			ref = sc.Org.String()
		}
		return wfActor{person: caller, handle: s.handleOf(ctx, caller), org: sc.Org, orgRef: ref}
	}
	request := func(in map[string]json.RawMessage) (WorkflowRequest, error) {
		var r WorkflowRequest
		b, _ := json.Marshal(in)
		if err := json.Unmarshal(b, &r); err != nil {
			return r, errs.InvalidArgument("invalid workflow request")
		}
		return r, nil
	}
	scoped("workflow_validate", "Check a workflow installer document without running it", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return s.ValidateWorkflow(ctx, actor(ctx, caller, sc, in), in["workflow"])
	})
	start := func(mode string) func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
			if err := sc.Require("resources"); err != nil {
				return nil, err
			}
			r, err := request(in)
			if err != nil {
				return nil, err
			}
			if mode != "" {
				r.Mode = mode
			}
			return s.StartWorkflow(ctx, actor(ctx, caller, sc, in), r)
		}
	}
	scoped("workflow_plan", "Dry-run a workflow: what it would create, update and run", start(workflow.ModePlan))
	scoped("workflow_run", "Run a workflow installer (async: true answers at once)", start(""))
	scoped("workflow_runs", "An organization's recent workflow runs", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var limit int
		_ = json.Unmarshal(in["limit"], &limit)
		runs, err := s.WorkflowRuns(ctx, sc.Org, limit)
		return map[string]any{"runs": runs}, err
	})
	scoped("workflow_run_get", "A workflow run with its report", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var id string
		_ = json.Unmarshal(in["id"], &id)
		return s.WorkflowRun(ctx, sc.Org, id)
	})
	scoped("workflow_run_cancel", "Cancel a running workflow", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		var id string
		_ = json.Unmarshal(in["id"], &id)
		return s.CancelWorkflow(ctx, sc.Org, caller, id)
	})
	scoped("workflow_reference", "The workflow format: step kinds, built-in resources and functions", func(context.Context, identity.ID, Scope, map[string]json.RawMessage) (any, error) {
		return WorkflowReference(), nil
	})
	scoped("workflow_guide", "How to write a rich, professional workflow (markdown), for models and people", func(context.Context, identity.ID, Scope, map[string]json.RawMessage) (any, error) {
		return workflowGuide(), nil
	})
	scoped("workflow_schema", "The workflow format as a JSON Schema, for editors", func(context.Context, identity.ID, Scope, map[string]json.RawMessage) (any, error) {
		return workflow.JSONSchema(), nil
	})
}

// ---- the developer host ----

func (s *Service) keyActor(ctx context.Context, p *Principal) (wfActor, error) {
	person, handle, err := s.ActorFor(p)
	if err != nil {
		return wfActor{}, err
	}
	ref := p.Org.String()
	if p.Org == person {
		ref = PersonalOrg
	}
	return wfActor{person: person, handle: handle, org: p.Org, orgRef: ref, key: p}, nil
}

func (s *Service) apiWorkflows() []route {
	get := func(p string, h network.Handler) route { return route{network.MethodGet, apiPrefix + p, h} }
	post := func(p string, h network.Handler) route { return route{network.MethodPost, apiPrefix + p, h} }
	const res, svc = "platform", "workflows"
	r, w := LevelRead, LevelWrite
	start := func(mode string) func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
		return func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			var in WorkflowRequest
			if err := jsonBody(req, &in); err != nil {
				return nil, 0, err
			}
			if mode != "" {
				in.Mode = mode
			}
			a, err := s.keyActor(ctx, p)
			if err != nil {
				return nil, 0, err
			}
			if strings.EqualFold(in.Mode, "validate") {
				out, err := s.ValidateWorkflow(ctx, a, in.Workflow)
				return out, http.StatusOK, err
			}
			view, err := s.StartWorkflow(ctx, a, in)
			if err != nil {
				return nil, 0, err
			}
			if view.Status == workflow.StatusRunning {
				return view, http.StatusAccepted, nil
			}
			return view, http.StatusOK, nil
		}
	}
	return []route{
		get("/workflows/reference", s.resource(res, r, svc, func(context.Context, *Principal, *network.Request) (any, int, error) {
			return WorkflowReference(), http.StatusOK, nil
		})),
		get("/workflows/schema", s.resource(res, r, svc, func(context.Context, *Principal, *network.Request) (any, int, error) {
			return workflow.JSONSchema(), http.StatusOK, nil
		})),
		get("/workflows/guide", s.resource(res, r, svc, func(context.Context, *Principal, *network.Request) (any, int, error) {
			return workflowGuide(), http.StatusOK, nil
		})),
		post("/workflows/validate", s.resourceLogged(res, r, svc, false, start("validate"))),
		post("/workflows/plan", s.resourceLogged(res, w, svc, false, start(workflow.ModePlan))),
		post("/workflows/runs", s.resourceLogged(res, w, svc, false, start(""))),
		get("/workflows/runs", s.resource(res, r, svc, func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			limit, _ := strconv.Atoi(req.Query.Get("limit"))
			runs, err := s.WorkflowRuns(ctx, p.Org, limit)
			return map[string]any{"object": "list", "data": runs}, http.StatusOK, err
		})),
		get("/workflows/runs/{id}", s.resource(res, r, svc, func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.WorkflowRun(ctx, p.Org, param(req, "id"))
			return v, http.StatusOK, err
		})),
		post("/workflows/runs/{id}/cancel", s.resource(res, w, svc, func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.CancelWorkflow(ctx, p.Org, p.Key.CreatedBy, param(req, "id"))
			return v, http.StatusOK, err
		})),
	}
}
