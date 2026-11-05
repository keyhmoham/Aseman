package workflow

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"mime"
	pathpkg "path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Caller is how the engine reaches the platform.
type Caller interface {
	// Call runs "namespace.action" with a JSON-shaped request and answers
	// its decoded JSON response.
	Call(ctx context.Context, action string, with map[string]any) (any, error)
	// Model runs a model request (type: chat, embeddings, image, …).
	Model(ctx context.Context, typ string, body map[string]any) (any, error)
}

// Modes.
const (
	ModeRun  = "run"
	ModePlan = "plan"
)

// Run statuses.
const (
	StatusRunning    = "running"
	StatusSucceeded  = "succeeded"
	StatusFailed     = "failed"
	StatusCancelled  = "cancelled"
	StatusRolledBack = "rolled_back"
	StatusPlanned    = "planned"
	StatusSkipped    = "skipped"
	StatusReused     = "reused"
)

// Options configure one run.
type Options struct {
	Mode    string
	Inputs  map[string]any
	Secrets map[string]string
	// Run is exposed to expressions as `run` (id, org, actor, …).
	Run map[string]any
	// ErrorCode classifies a Caller's error (not_found, unavailable, …).
	ErrorCode func(error) string
	// OnProgress is told after each step (the report is a snapshot).
	OnProgress func(*Report)
	// Resume reuses the outputs of top-level steps a previous run finished
	// (by id), instead of running them again.
	Resume map[string]any
	Now    func() time.Time
	Sleep  func(ctx context.Context, d time.Duration) error
}

// Report is what a run did.
type Report struct {
	Workflow   string         `json:"workflow"`
	Version    string         `json:"version,omitempty"`
	Mode       string         `json:"mode"`
	Status     string         `json:"status"`
	Error      string         `json:"error,omitempty"`
	ErrorCode  string         `json:"error_code,omitempty"`
	ErrorPath  string         `json:"error_path,omitempty"`
	Issues     []Issue        `json:"issues,omitempty"`
	Inputs     map[string]any `json:"inputs,omitempty"`
	Outputs    map[string]any `json:"outputs,omitempty"`
	Steps      []*StepRecord  `json:"steps"`
	Rollback   []*StepRecord  `json:"rollback,omitempty"`
	Events     []Event        `json:"events"`
	Counts     Counts         `json:"counts"`
	StartedAt  time.Time      `json:"started_at"`
	FinishedAt time.Time      `json:"finished_at,omitempty"`
	DurationMs int64          `json:"duration_ms"`
}

// Counts sums the step records.
type Counts struct {
	Total     int `json:"total"`
	Succeeded int `json:"succeeded"`
	Failed    int `json:"failed"`
	Skipped   int `json:"skipped"`
	Planned   int `json:"planned"`
	Reused    int `json:"reused"`
	Created   int `json:"created"`
	Updated   int `json:"updated"`
	Unchanged int `json:"unchanged"`
}

// StepRecord is one step as it ran.
type StepRecord struct {
	Path       string    `json:"path"`
	ID         string    `json:"id,omitempty"`
	Name       string    `json:"name,omitempty"`
	Kind       string    `json:"kind"`
	Action     string    `json:"action,omitempty"`
	Status     string    `json:"status"`
	Reason     string    `json:"reason,omitempty"`
	Operation  string    `json:"operation,omitempty"`
	Attempts   int       `json:"attempts,omitempty"`
	Request    any       `json:"request,omitempty"`
	Outputs    any       `json:"outputs,omitempty"`
	Error      string    `json:"error,omitempty"`
	ErrorCode  string    `json:"error_code,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	FinishedAt time.Time `json:"finished_at,omitempty"`
	DurationMs int64     `json:"duration_ms"`
}

// Event is a line of the run's log.
type Event struct {
	Time    time.Time `json:"time"`
	Level   string    `json:"level"`
	Path    string    `json:"path,omitempty"`
	Message string    `json:"message"`
}

// StepError is a failed step.
type StepError struct {
	Path    string
	Code    string
	Message string
	Err     error
}

func (e *StepError) Error() string {
	if e.Path == "" {
		return e.Message
	}
	return e.Path + ": " + e.Message
}
func (e *StepError) Unwrap() error { return e.Err }

const maxEvents = 5000

type undo struct {
	path string
	desc string
	fn   func(ctx context.Context) error
}

type runner struct {
	wf     *Workflow
	opts   Options
	caller Caller

	mu       sync.Mutex
	report   *Report
	vars     map[string]any
	inputs   map[string]any
	secrets  map[string]any
	assets   map[string]any
	blobs    map[string][]byte
	undos    []undo
	redactor *redactor

	executed atomic.Int64
	maxSteps int64
}

// Run validates and runs (or plans) a workflow. The report is complete
// whatever happens; its Status says how it went.
func Run(ctx context.Context, wf *Workflow, caller Caller, cat Catalog, opts Options) *Report {
	if opts.Mode == "" {
		opts.Mode = ModeRun
	}
	if opts.Now == nil {
		opts.Now = func() time.Time { return time.Now().UTC() }
	}
	if opts.Sleep == nil {
		opts.Sleep = sleepCtx
	}
	if opts.ErrorCode == nil {
		opts.ErrorCode = func(error) string { return "error" }
	}
	r := &runner{wf: wf, opts: opts, caller: caller, vars: map[string]any{}, assets: map[string]any{}, blobs: map[string][]byte{}}
	r.report = &Report{Workflow: wf.Name, Version: wf.Version, Mode: opts.Mode, Status: StatusRunning, StartedAt: opts.Now(), Steps: []*StepRecord{}, Events: []Event{}}
	r.maxSteps = MaxSteps
	if wf.Options.MaxSteps > 0 {
		r.maxSteps = int64(wf.Options.MaxSteps)
	}

	issues := Validate(wf, cat)
	inputs, inIssues := ResolveInputs(wf.Inputs, opts.Inputs)
	issues = append(issues, inIssues...)
	r.inputs = inputs
	r.secrets = map[string]any{}
	var secretValues []string
	for _, s := range wf.Secrets {
		v, ok := opts.Secrets[s.Name]
		if !ok && s.Required && opts.Mode == ModeRun {
			issues = append(issues, Issue{Path: "secrets." + s.Name, Message: "is required", Severity: "error"})
		}
		if ok {
			r.secrets[s.Name] = v
			secretValues = append(secretValues, v)
		} else if opts.Mode == ModePlan {
			r.secrets[s.Name] = &Unknown{Ref: "secrets." + s.Name}
		}
	}
	for name, spec := range wf.Inputs {
		if spec.Sensitive {
			if s, ok := inputs[name].(string); ok {
				secretValues = append(secretValues, s)
			}
		}
	}
	r.redactor = newRedactor(secretValues)
	r.report.Inputs = r.redactor.value(inputs, 0).(map[string]any)
	r.report.Issues = issues
	if HasErrors(issues) {
		return r.finish(StatusFailed, &StepError{Code: "invalid_workflow", Message: firstError(issues)})
	}
	if err := r.loadAssets(); err != nil {
		return r.finish(StatusFailed, &StepError{Path: "assets", Code: "invalid_workflow", Message: err.Error()})
	}

	timeout := DefaultRunTimeout
	if t := wf.Options.Timeout; t != nil && t.Duration > 0 {
		timeout = min(t.Duration, MaxRunTimeout)
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	root := newScope(nil)
	if err := r.computeVars(root); err != nil {
		return r.finish(StatusFailed, err)
	}
	r.event("info", "", fmt.Sprintf("%s %s: %d step(s)", map[string]string{ModeRun: "running", ModePlan: "planning"}[opts.Mode], wf.Name, len(wf.Steps)))

	_, err := r.steps(ctx, root, wf.Steps, "steps", true)
	status := StatusSucceeded
	if opts.Mode == ModePlan {
		status = StatusPlanned
	}
	if err != nil {
		status = StatusFailed
		if ctx.Err() != nil {
			status = StatusCancelled
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				err = &StepError{Code: "timeout", Message: "the run took longer than " + timeout.String(), Err: err}
			}
		}
		if wf.Options.RollbackOnFailure && opts.Mode == ModeRun {
			r.rollback(context.WithoutCancel(ctx))
			if status == StatusFailed {
				status = StatusRolledBack
			}
		}
		if len(wf.OnFailure) > 0 {
			fs := newScope(root)
			fs.locals["failure"] = r.failureInfo(err)
			if _, ferr := r.steps(context.WithoutCancel(ctx), fs, wf.OnFailure, "on_failure", false); ferr != nil {
				r.event("error", "on_failure", ferr.Error())
			}
		}
	}
	if len(wf.Finally) > 0 {
		fs := newScope(root)
		fs.locals["outcome"] = map[string]any{"status": status, "error": errText(err)}
		if _, ferr := r.steps(context.WithoutCancel(ctx), fs, wf.Finally, "finally", false); ferr != nil {
			r.event("error", "finally", ferr.Error())
			if err == nil {
				err, status = ferr, StatusFailed
			}
		}
	}
	if wf.Outputs != nil {
		out, oerr := Render(map[string]any(wf.Outputs), r.env(root, nil))
		if oerr != nil && err == nil {
			err, status = &StepError{Path: "outputs", Code: "invalid_workflow", Message: oerr.Error()}, StatusFailed
		}
		if m, ok := out.(map[string]any); ok {
			r.report.Outputs = r.redactor.value(m, 0).(map[string]any)
		}
	}
	return r.finish(status, err)
}

func firstError(issues []Issue) string {
	for _, i := range issues {
		if i.Severity == "error" {
			msg := i.Path + ": " + i.Message
			if n := countErrors(issues); n > 1 {
				msg += fmt.Sprintf(" (and %d more)", n-1)
			}
			return msg
		}
	}
	return "the workflow is not valid"
}

func countErrors(issues []Issue) int {
	n := 0
	for _, i := range issues {
		if i.Severity == "error" {
			n++
		}
	}
	return n
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (r *runner) failureInfo(err error) map[string]any {
	info := map[string]any{"message": errText(err)}
	var se *StepError
	if errors.As(err, &se) {
		info["path"], info["code"] = se.Path, se.Code
		info["message"] = se.Message
	}
	return info
}

func (r *runner) finish(status string, err error) *Report {
	r.mu.Lock()
	defer r.mu.Unlock()
	rep := r.report
	rep.Status = status
	if err != nil {
		var se *StepError
		if errors.As(err, &se) {
			rep.Error, rep.ErrorCode, rep.ErrorPath = r.redactor.text(se.Message), se.Code, se.Path
		} else {
			rep.Error, rep.ErrorCode = r.redactor.text(err.Error()), r.opts.ErrorCode(err)
		}
		r.eventLocked("error", rep.ErrorPath, rep.Error)
	}
	rep.FinishedAt = r.opts.Now()
	rep.DurationMs = rep.FinishedAt.Sub(rep.StartedAt).Milliseconds()
	rep.Counts = Counts{}
	for _, s := range rep.Steps {
		rep.Counts.Total++
		switch s.Status {
		case StatusSucceeded:
			rep.Counts.Succeeded++
		case StatusFailed:
			rep.Counts.Failed++
		case StatusSkipped:
			rep.Counts.Skipped++
		case StatusPlanned:
			rep.Counts.Planned++
		case StatusReused:
			rep.Counts.Reused++
		}
		switch s.Operation {
		case "created", "would_create":
			rep.Counts.Created++
		case "updated", "would_update":
			rep.Counts.Updated++
		case "unchanged":
			rep.Counts.Unchanged++
		}
	}
	return rep
}

func (r *runner) snapshot() {
	if r.opts.OnProgress == nil {
		return
	}
	r.mu.Lock()
	cp := *r.report
	cp.Steps = append([]*StepRecord(nil), r.report.Steps...)
	cp.Events = append([]Event(nil), r.report.Events...)
	r.mu.Unlock()
	r.opts.OnProgress(&cp)
}

func (r *runner) event(level, path, msg string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.eventLocked(level, path, msg)
}

func (r *runner) eventLocked(level, path, msg string) {
	if len(r.report.Events) >= maxEvents {
		return
	}
	r.report.Events = append(r.report.Events, Event{Time: r.opts.Now(), Level: level, Path: path, Message: r.redactor.text(clipText(msg, 4000))})
}

func (r *runner) loadAssets() error {
	for name, a := range r.wf.Assets {
		var data []byte
		switch {
		case a.Content != nil:
			data = []byte(*a.Content)
		case a.Base64 != "":
			b, err := base64.StdEncoding.DecodeString(a.Base64)
			if err != nil {
				return fmt.Errorf("%s: bad base64", name)
			}
			data = b
		default:
			data = []byte(mustJSON(a.JSON))
		}
		r.blobs[name] = data
		mt := a.Mime
		if mt == "" {
			mt = mime.TypeByExtension(pathpkg.Ext(name))
		}
		r.assets[name] = map[string]any{"name": name, "size": float64(len(data)), "mime": mt}
	}
	return nil
}

func (r *runner) computeVars(root *scope) error {
	order, err := varOrder(r.wf.Vars)
	if err != nil {
		return &StepError{Path: "vars", Code: "invalid_workflow", Message: err.Error()}
	}
	for _, name := range order {
		v, err := Render(r.wf.Vars[name], r.env(root, nil))
		if err != nil {
			return &StepError{Path: "vars." + name, Code: "invalid_workflow", Message: err.Error()}
		}
		r.setVar(name, v)
	}
	return nil
}

func (r *runner) setVar(name string, v any) {
	r.mu.Lock()
	r.vars[name] = v
	r.mu.Unlock()
}

// ---- scopes & environment ----

type scope struct {
	parent *scope
	mu     sync.Mutex
	steps  map[string]any
	locals map[string]any
	// isolated scopes (templates) do not see their parents' steps.
	isolated bool
}

func newScope(parent *scope) *scope {
	return &scope{parent: parent, steps: map[string]any{}, locals: map[string]any{}}
}

func (s *scope) setStep(id string, state map[string]any) {
	if id == "" {
		return
	}
	s.mu.Lock()
	s.steps[id] = state
	s.mu.Unlock()
}

func (s *scope) local(name string) (any, bool) {
	for c := s; c != nil; c = c.parent {
		c.mu.Lock()
		v, ok := c.locals[name]
		c.mu.Unlock()
		if ok {
			return v, true
		}
	}
	return nil, false
}

func (s *scope) allSteps() map[string]any {
	var chain []*scope
	for c := s; c != nil; c = c.parent {
		chain = append(chain, c)
		if c.isolated {
			break
		}
	}
	out := map[string]any{}
	for i := len(chain) - 1; i >= 0; i-- {
		c := chain[i]
		c.mu.Lock()
		for k, v := range c.steps {
			out[k] = v
		}
		c.mu.Unlock()
	}
	return out
}

type env struct {
	r     *runner
	sc    *scope
	extra map[string]any
}

func (r *runner) env(sc *scope, extra map[string]any) Env { return &env{r: r, sc: sc, extra: extra} }

func (e *env) Lookup(name string) (any, bool) {
	if v, ok := e.extra[name]; ok {
		return v, true
	}
	if v, ok := e.sc.local(name); ok {
		return v, true
	}
	switch name {
	case "inputs":
		return e.r.inputs, true
	case "vars":
		e.r.mu.Lock()
		cp := make(map[string]any, len(e.r.vars))
		for k, v := range e.r.vars {
			cp[k] = v
		}
		e.r.mu.Unlock()
		return cp, true
	case "secrets":
		return e.r.secrets, true
	case "steps":
		return e.sc.allSteps(), true
	case "assets":
		return e.r.assets, true
	case "run":
		info := map[string]any{"mode": e.r.opts.Mode, "workflow": e.r.wf.Name, "version": e.r.wf.Version}
		for k, v := range e.r.opts.Run {
			info[k] = v
		}
		return info, true
	}
	return nil, false
}

func (e *env) Func(name string) (Func, bool) {
	switch name {
	case "file":
		return func(_ Env, a []any) (any, error) {
			b, ok := e.r.blobs[str(a, 0)]
			if !ok {
				return nil, fmt.Errorf("no asset %q", str(a, 0))
			}
			return string(b), nil
		}, true
	case "file_base64":
		return func(_ Env, a []any) (any, error) {
			b, ok := e.r.blobs[str(a, 0)]
			if !ok {
				return nil, fmt.Errorf("no asset %q", str(a, 0))
			}
			return base64.StdEncoding.EncodeToString(b), nil
		}, true
	case "files":
		return func(_ Env, a []any) (any, error) {
			prefix := str(a, 0)
			out := map[string]any{}
			for name, b := range e.r.blobs {
				if strings.HasPrefix(name, prefix) {
					out[strings.TrimPrefix(name, prefix)] = string(b)
				}
			}
			return out, nil
		}, true
	}
	b, ok := builtins[name]
	return b.fn, ok
}

// ---- steps ----

func (r *runner) steps(ctx context.Context, sc *scope, list []*Step, path string, top bool) (any, error) {
	var last any
	for i, s := range list {
		if err := ctx.Err(); err != nil {
			return last, &StepError{Path: path, Code: "cancelled", Message: "the run was cancelled", Err: err}
		}
		out, err := r.step(ctx, sc, s, stepPath(path, i, s), top)
		if err != nil {
			return last, err
		}
		last = out
	}
	return last, nil
}

func stepPath(parent string, i int, s *Step) string {
	p := fmt.Sprintf("%s[%d]", parent, i)
	if s != nil && s.ID != "" {
		p = parent + "." + s.ID
		if parent == "steps" {
			p = s.ID
		}
	}
	return p
}

func (r *runner) newRecord(s *Step, path string) *StepRecord {
	rec := &StepRecord{Path: path, ID: s.ID, Name: s.Name, Kind: s.Kind(), Status: StatusRunning, StartedAt: r.opts.Now()}
	if s.ForEach != nil {
		rec.Kind = "for_each:" + rec.Kind
	}
	switch {
	case s.Action != "":
		rec.Action = s.Action
	case s.Upsert != nil:
		rec.Action = "upsert:" + s.Upsert.Resource
	case s.Wait != nil:
		rec.Action = s.Wait.Action
	case s.Use != "":
		rec.Action = "template:" + s.Use
	case s.Model != nil:
		rec.Action = "model:" + firstNonEmpty(s.Model.Type, "chat")
	}
	r.mu.Lock()
	r.report.Steps = append(r.report.Steps, rec)
	r.mu.Unlock()
	return rec
}

func firstNonEmpty(a ...string) string {
	for _, s := range a {
		if s != "" {
			return s
		}
	}
	return ""
}

func (r *runner) closeRecord(rec *StepRecord, status string, outputs any, err error) {
	r.mu.Lock()
	rec.Status = status
	rec.FinishedAt = r.opts.Now()
	rec.DurationMs = rec.FinishedAt.Sub(rec.StartedAt).Milliseconds()
	if outputs != nil {
		if rec.Request == "(sensitive)" {
			rec.Outputs = "(sensitive)"
		} else {
			rec.Outputs = r.redactor.value(outputs, 0)
		}
	}
	if err != nil {
		var se *StepError
		if errors.As(err, &se) {
			rec.Error, rec.ErrorCode = r.redactor.text(se.Message), se.Code
		} else {
			rec.Error, rec.ErrorCode = r.redactor.text(err.Error()), r.opts.ErrorCode(err)
		}
	}
	r.mu.Unlock()
	r.snapshot()
}

func (r *runner) setRequest(rec *StepRecord, req any, sensitive bool) {
	if sensitive {
		req = "(sensitive)"
	}
	r.mu.Lock()
	rec.Request = r.redactor.value(req, 0)
	r.mu.Unlock()
}

func (r *runner) step(ctx context.Context, sc *scope, s *Step, path string, top bool) (any, error) {
	if r.executed.Add(1) > r.maxSteps {
		return nil, &StepError{Path: path, Code: "limit", Message: fmt.Sprintf("the run executed more than %d steps", r.maxSteps)}
	}
	rec := r.newRecord(s, path)
	if s.Sensitive {
		rec.Request = "(sensitive)"
	}
	// Resumed: a previous run finished this step.
	if top && s.ID != "" && r.opts.Resume != nil {
		if prev, ok := r.opts.Resume[s.ID]; ok {
			sc.setStep(s.ID, map[string]any{"status": StatusReused, "outputs": prev})
			rec.Reason = "finished by the run this one resumes"
			r.closeRecord(rec, StatusReused, prev, nil)
			return prev, nil
		}
	}
	if s.If != nil {
		ok, err := EvalCondition(s.If, r.env(sc, nil))
		if err != nil {
			e := &StepError{Path: path, Code: "invalid_workflow", Message: "if: " + err.Error()}
			r.closeRecord(rec, StatusFailed, nil, e)
			return nil, e
		}
		if u, unknown := ok.(*Unknown); unknown {
			rec.Reason = "runs only if " + u.String()
		} else if !Truthy(ok) {
			rec.Reason = "condition is false"
			sc.setStep(s.ID, map[string]any{"status": StatusSkipped, "outputs": nil, "skipped": true})
			r.closeRecord(rec, StatusSkipped, nil, nil)
			return nil, nil
		}
	}
	if s.Plan == "skip" && r.opts.Mode == ModePlan {
		rec.Reason = "not planned (plan: skip)"
		sc.setStep(s.ID, map[string]any{"status": StatusSkipped, "outputs": r.unknownOutputs(s)})
		r.closeRecord(rec, StatusSkipped, nil, nil)
		return r.unknownOutputs(s), nil
	}

	var out any
	var err error
	if s.ForEach != nil {
		out, err = r.loop(ctx, sc, s, path)
	} else {
		out, err = r.attempts(ctx, sc, s, path, rec)
	}

	if err == nil && (s.Outputs != nil || s.Export != nil) {
		resultEnv := r.env(sc, map[string]any{"result": out})
		if s.Outputs != nil {
			shaped, oerr := Render(s.Outputs, resultEnv)
			if oerr != nil {
				err = &StepError{Path: path, Code: "invalid_workflow", Message: "outputs: " + oerr.Error()}
			} else {
				out = shaped
			}
		}
		if err == nil {
			exportEnv := r.env(sc, map[string]any{"result": out})
			for _, k := range sortedKeysAny(s.Export) {
				v, xerr := Render(s.Export[k], exportEnv)
				if xerr != nil {
					err = &StepError{Path: path, Code: "invalid_workflow", Message: "export." + k + ": " + xerr.Error()}
					break
				}
				r.setVar(k, v)
			}
		}
	}

	status := StatusSucceeded
	if r.opts.Mode == ModePlan && rec.Status != StatusSucceeded {
		status = StatusPlanned
	}
	if err != nil {
		status = StatusFailed
		if len(s.OnError) > 0 {
			es := newScope(sc)
			es.locals["error"] = r.failureInfo(err)
			if _, herr := r.steps(ctx, es, s.OnError, path+".on_error", false); herr != nil {
				r.event("error", path+".on_error", herr.Error())
			}
		}
		state := map[string]any{"status": StatusFailed, "outputs": nil, "error": r.failureInfo(err)}
		sc.setStep(s.ID, state)
		r.closeRecord(rec, StatusFailed, nil, err)
		if s.ContinueOnError || (r.wf.Defaults.ContinueOnError && !isStructural(err)) {
			r.event("warning", path, "failed, continuing: "+err.Error())
			return nil, nil
		}
		var se *StepError
		if !errors.As(err, &se) {
			err = &StepError{Path: path, Code: r.opts.ErrorCode(err), Message: err.Error(), Err: err}
		}
		return nil, err
	}
	state := map[string]any{"status": status, "outputs": out}
	if m, ok := out.(map[string]any); ok && s.Upsert != nil {
		state["id"], state["operation"] = m["id"], m["operation"]
	}
	sc.setStep(s.ID, state)
	if s.Compensate != nil && r.opts.Mode == ModeRun {
		comp, compScope, compOut := s.Compensate, sc, out
		r.pushUndo(path, "compensate", func(ctx context.Context) error {
			cs := newScope(compScope)
			cs.locals["result"] = compOut
			_, err := r.step(ctx, cs, comp, "rollback."+path, false)
			return err
		})
	}
	r.closeRecord(rec, status, out, nil)
	return out, nil
}

func isStructural(err error) bool {
	var se *StepError
	return errors.As(err, &se) && (se.Code == "invalid_workflow" || se.Code == "limit" || se.Code == "cancelled")
}

func sortedKeysAny(m map[string]any) []string { return sortedKeys(m) }

func (r *runner) pushUndo(path, desc string, fn func(ctx context.Context) error) {
	r.mu.Lock()
	r.undos = append(r.undos, undo{path: path, desc: desc, fn: fn})
	r.mu.Unlock()
}

func (r *runner) rollback(ctx context.Context) {
	r.mu.Lock()
	undos := r.undos
	r.undos = nil
	r.mu.Unlock()
	if len(undos) == 0 {
		return
	}
	r.event("warning", "", fmt.Sprintf("rolling back %d change(s)", len(undos)))
	for i := len(undos) - 1; i >= 0; i-- {
		u := undos[i]
		rec := &StepRecord{Path: "rollback." + u.path, Kind: "rollback", Action: u.desc, Status: StatusRunning, StartedAt: r.opts.Now()}
		err := u.fn(ctx)
		rec.FinishedAt = r.opts.Now()
		rec.DurationMs = rec.FinishedAt.Sub(rec.StartedAt).Milliseconds()
		rec.Status = StatusSucceeded
		if err != nil {
			rec.Status, rec.Error = StatusFailed, r.redactor.text(err.Error())
			r.event("error", rec.Path, "rollback failed: "+err.Error())
		}
		r.mu.Lock()
		r.report.Rollback = append(r.report.Rollback, rec)
		r.mu.Unlock()
	}
}

// attempts runs a step's kind with its retry and timeout.
func (r *runner) attempts(ctx context.Context, sc *scope, s *Step, path string, rec *StepRecord) (any, error) {
	retry := s.Retry
	if retry == nil {
		retry = r.wf.Defaults.Retry
	}
	n := 1
	if retry != nil && retry.Attempts > 1 {
		n = min(retry.Attempts, MaxAttempts)
	}
	timeout := time.Duration(0)
	if s.Timeout != nil {
		timeout = s.Timeout.Duration
	} else if r.wf.Defaults.Timeout != nil && !isContainer(s) {
		timeout = r.wf.Defaults.Timeout.Duration
	}
	delay := time.Second
	if retry != nil && retry.Delay != nil {
		delay = retry.Delay.Duration
	}
	var lastErr error
	for attempt := 1; attempt <= n; attempt++ {
		r.mu.Lock()
		rec.Attempts = attempt
		r.mu.Unlock()
		actx, cancel := ctx, context.CancelFunc(func() {})
		if timeout > 0 {
			actx, cancel = context.WithTimeout(ctx, timeout)
		}
		out, err := r.kind(actx, sc, s, path, rec, attempt)
		timedOut := timeout > 0 && errors.Is(actx.Err(), context.DeadlineExceeded) && ctx.Err() == nil
		cancel()
		if err == nil {
			return out, nil
		}
		if timedOut {
			err = &StepError{Path: path, Code: "timeout", Message: "took longer than " + timeout.String(), Err: err}
		}
		lastErr = err
		if attempt == n || ctx.Err() != nil || !r.retryable(err, retry) {
			break
		}
		wait := delay
		if retry.Backoff > 1 {
			wait = time.Duration(float64(delay) * pow(retry.Backoff, attempt-1))
		}
		if retry.MaxDelay != nil && wait > retry.MaxDelay.Duration {
			wait = retry.MaxDelay.Duration
		}
		r.event("warning", path, fmt.Sprintf("attempt %d of %d failed (%s); retrying in %s", attempt, n, errText(err), wait))
		if serr := r.opts.Sleep(ctx, wait); serr != nil {
			return nil, lastErr
		}
	}
	return nil, lastErr
}

func pow(b float64, e int) float64 {
	out := 1.0
	for i := 0; i < e; i++ {
		out *= b
	}
	return out
}

func isContainer(s *Step) bool { return s.Steps != nil || s.Use != "" || s.ForEach != nil }

var notRetryable = map[string]bool{"invalid_argument": true, "permission": true, "not_found": true, "already_exists": true,
	"assertion": true, "failed": true, "invalid_workflow": true, "limit": true, "cancelled": true, "unauthenticated": true, "finance": true}

func (r *runner) retryable(err error, retry *Retry) bool {
	if retry == nil {
		return false
	}
	code := r.codeOf(err)
	if len(retry.On) > 0 {
		for _, c := range retry.On {
			if strings.EqualFold(c, code) || c == "*" {
				return true
			}
		}
		return false
	}
	return !notRetryable[code]
}

func (r *runner) codeOf(err error) string {
	var se *StepError
	if errors.As(err, &se) && se.Code != "" {
		return se.Code
	}
	return r.opts.ErrorCode(err)
}

// kind runs one attempt of a step's kind.
func (r *runner) kind(ctx context.Context, sc *scope, s *Step, path string, rec *StepRecord, attempt int) (any, error) {
	e := r.env(sc, map[string]any{"attempt": float64(attempt)})
	plan := r.opts.Mode == ModePlan
	switch s.Kind() {
	case "action":
		with, err := r.request(s.Action, s.With, e)
		if err != nil {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "with: " + err.Error()}
		}
		r.setRequest(rec, with, s.Sensitive)
		if plan && (s.Plan != "run" || hasUnknown(with)) {
			return r.unknownOutputs(s), nil
		}
		if plan {
			r.mu.Lock()
			rec.Status = StatusSucceeded
			r.mu.Unlock()
		}
		return r.call(ctx, path, s.Action, with)
	case "upsert":
		return r.upsert(ctx, sc, s, path, rec)
	case "model":
		body, err := Render(s.Model.Body, e)
		if err != nil {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "body: " + err.Error()}
		}
		m, ok := body.(map[string]any)
		if !ok {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "model.body must be an object"}
		}
		r.setRequest(rec, m, s.Sensitive)
		if plan {
			return r.unknownOutputs(s), nil
		}
		return r.caller.Model(ctx, firstNonEmpty(s.Model.Type, "chat"), m)
	case "sandbox":
		return r.sandbox(ctx, sc, s, path, rec)
	case "wait":
		return r.wait(ctx, sc, s, path, rec)
	case "set":
		vals := map[string]any{}
		for _, k := range sortedKeys(s.Set) {
			v, err := Render(s.Set[k], e)
			if err != nil {
				return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "set." + k + ": " + err.Error()}
			}
			vals[k] = v
		}
		for k, v := range vals {
			r.setVar(k, v)
		}
		return vals, nil
	case "assert":
		return nil, r.assert(s.Assert, e, path)
	case "log":
		v, err := Render(s.Log, e)
		if err != nil {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: err.Error()}
		}
		r.event("info", path, ToString(v))
		return v, nil
	case "sleep":
		if !plan {
			if err := r.opts.Sleep(ctx, s.Sleep.Duration); err != nil {
				return nil, err
			}
		}
		return nil, nil
	case "fail":
		v, err := Render(s.Fail, e)
		if err != nil {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: err.Error()}
		}
		if _, unknown := v.(*Unknown); unknown && plan {
			return nil, nil
		}
		if plan && strings.HasPrefix(rec.Reason, "runs only if") {
			r.event("warning", path, "would fail: "+ToString(v))
			return nil, nil
		}
		return nil, &StepError{Path: path, Code: "failed", Message: ToString(v)}
	case "group":
		if s.Parallel {
			return r.parallel(ctx, sc, s.Steps, path)
		}
		return r.steps(ctx, sc, s.Steps, path, false)
	case "template":
		return r.template(ctx, sc, s, path, e)
	}
	return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "a step needs exactly one kind"}
}

func (r *runner) unknownOutputs(s *Step) any {
	ref := "output"
	if s.ID != "" {
		ref = "steps." + s.ID + ".outputs"
	}
	return &Unknown{Ref: ref}
}

func (r *runner) unknownID(s *Step) any {
	if s.ID != "" {
		return &Unknown{Ref: "steps." + s.ID + ".outputs.id"}
	}
	return &Unknown{Ref: "id"}
}

func hasUnknown(v any) bool {
	switch x := v.(type) {
	case *Unknown:
		return true
	case []any:
		for _, e := range x {
			if hasUnknown(e) {
				return true
			}
		}
	case map[string]any:
		for _, e := range x {
			if hasUnknown(e) {
				return true
			}
		}
	}
	return false
}

// request renders an action's `with`, laying the namespace's defaults under it.
func (r *runner) request(action string, with any, e Env) (map[string]any, error) {
	rendered, err := Render(with, e)
	if err != nil {
		return nil, err
	}
	m := map[string]any{}
	switch x := rendered.(type) {
	case nil:
	case map[string]any:
		m = x
	case *Unknown:
		return map[string]any{"$unknown": x.String()}, nil
	default:
		return nil, fmt.Errorf("must be an object, not %s", typeName(rendered))
	}
	ns, _, _ := strings.Cut(action, ".")
	if d := r.wf.Defaults.With[ns]; len(d) > 0 {
		base, err := Render(map[string]any(d), e)
		if err != nil {
			return nil, err
		}
		merged := map[string]any{}
		for k, v := range base.(map[string]any) {
			merged[k] = v
		}
		for k, v := range m {
			merged[k] = v
		}
		m = merged
	}
	return m, nil
}

func (r *runner) call(ctx context.Context, path, action string, with map[string]any) (any, error) {
	out, err := r.caller.Call(ctx, action, sanitize(with).(map[string]any))
	if err != nil {
		return nil, &StepError{Path: path, Code: r.opts.ErrorCode(err), Message: action + ": " + err.Error(), Err: err}
	}
	return out, nil
}

func (r *runner) assert(spec any, e Env, path string) error {
	type check struct {
		that any
		msg  any
	}
	var checks []check
	switch a := spec.(type) {
	case map[string]any:
		checks = append(checks, check{a["that"], a["message"]})
	case []any:
		for _, item := range a {
			if m, ok := item.(map[string]any); ok {
				checks = append(checks, check{m["that"], m["message"]})
			} else {
				checks = append(checks, check{item, nil})
			}
		}
	default:
		checks = append(checks, check{a, nil})
	}
	for _, c := range checks {
		v, err := EvalCondition(c.that, e)
		if err != nil {
			return &StepError{Path: path, Code: "invalid_workflow", Message: "assert: " + err.Error()}
		}
		if _, unknown := v.(*Unknown); unknown {
			continue
		}
		if !Truthy(v) {
			msg := "assertion failed: " + ToString(c.that)
			if c.msg != nil {
				if m, err := Render(c.msg, e); err == nil {
					msg = ToString(m)
				}
			}
			return &StepError{Path: path, Code: "assertion", Message: msg}
		}
	}
	return nil
}

func (r *runner) wait(ctx context.Context, sc *scope, s *Step, path string, rec *StepRecord) (any, error) {
	w := s.Wait
	e := r.env(sc, nil)
	with, err := r.request(w.Action, w.With, e)
	if err != nil {
		return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "wait.with: " + err.Error()}
	}
	r.setRequest(rec, with, s.Sensitive)
	if r.opts.Mode == ModePlan {
		return r.unknownOutputs(s), nil
	}
	interval, timeout := 5*time.Second, 10*time.Minute
	if w.Interval != nil && w.Interval.Duration > 0 {
		interval = w.Interval.Duration
	}
	if w.Timeout != nil && w.Timeout.Duration > 0 {
		timeout = w.Timeout.Duration
	}
	deadline := r.opts.Now().Add(timeout)
	for polls := 1; ; polls++ {
		out, err := r.call(ctx, path, w.Action, with)
		if err == nil {
			ok, cerr := EvalCondition(w.Until, r.env(sc, map[string]any{"result": out, "polls": float64(polls)}))
			if cerr != nil {
				return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "until: " + cerr.Error()}
			}
			if Truthy(ok) {
				return out, nil
			}
		} else if !r.retryable(err, &Retry{Attempts: 2}) {
			return nil, err
		}
		if !r.opts.Now().Add(interval).Before(deadline) {
			msg := "the condition did not hold within " + timeout.String()
			if err != nil {
				msg += " (last error: " + err.Error() + ")"
			}
			return nil, &StepError{Path: path, Code: "timeout", Message: msg}
		}
		if err := r.opts.Sleep(ctx, interval); err != nil {
			return nil, err
		}
	}
}

func (r *runner) parallel(ctx context.Context, sc *scope, list []*Step, path string) (any, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	outs := make([]any, len(list))
	errs := make([]error, len(list))
	sem := make(chan struct{}, MaxConcurrency)
	var wg sync.WaitGroup
	for i, s := range list {
		wg.Add(1)
		go func(i int, s *Step) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			outs[i], errs[i] = r.step(ctx, sc, s, stepPath(path, i, s), false)
			if errs[i] != nil {
				cancel()
			}
		}(i, s)
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil && !isCancelled(err) {
			return outs, err
		}
	}
	for _, err := range errs {
		if err != nil {
			return outs, err
		}
	}
	return outs, nil
}

func isCancelled(err error) bool {
	var se *StepError
	return errors.As(err, &se) && se.Code == "cancelled" || errors.Is(err, context.Canceled)
}

func (r *runner) loop(ctx context.Context, sc *scope, s *Step, path string) (any, error) {
	raw, err := Render(s.ForEach, r.env(sc, nil))
	if err != nil {
		return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "for_each: " + err.Error()}
	}
	var items []any
	switch x := raw.(type) {
	case []any:
		items = x
	case map[string]any:
		for _, k := range sortedKeys(x) {
			items = append(items, map[string]any{"key": k, "value": x[k]})
		}
	case float64:
		for i := 0; i < int(x) && i < MaxSteps; i++ {
			items = append(items, float64(i))
		}
	case nil:
	case *Unknown:
		if r.opts.Mode != ModePlan {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "for_each is not known"}
		}
		items = []any{&Unknown{Ref: x.Ref + "[*]"}}
	default:
		return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "for_each needs a list, an object or a number, not " + typeName(raw)}
	}
	body := *s
	body.ForEach, body.As, body.IndexAs, body.Collect, body.Concurrency = nil, "", "", nil, 0
	body.If, body.Outputs, body.Export, body.ID = nil, nil, nil, ""
	conc := 1
	if s.Concurrency > 1 && r.opts.Mode == ModeRun {
		conc = min(s.Concurrency, MaxConcurrency)
	}
	outs := make([]any, len(items))
	errs := make([]error, len(items))
	lctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sem := make(chan struct{}, conc)
	var wg sync.WaitGroup
	for i, item := range items {
		if lctx.Err() != nil {
			break
		}
		is := newScope(sc)
		as := firstNonEmpty(s.As, "item")
		is.locals[as] = item
		is.locals["item"] = item
		idx := firstNonEmpty(s.IndexAs, "index")
		is.locals[idx] = float64(i)
		is.locals["index"] = float64(i)
		is.locals["loop"] = map[string]any{"index": float64(i), "first": i == 0, "last": i == len(items)-1, "length": float64(len(items))}
		ipath := fmt.Sprintf("%s[%d]", path, i)
		run := func(i int, is *scope, ipath string) {
			out, err := r.step(lctx, is, &body, ipath, false)
			if err == nil && s.Collect != nil {
				out, err = Render(s.Collect, r.env(is, map[string]any{"result": out}))
				if err != nil {
					err = &StepError{Path: ipath, Code: "invalid_workflow", Message: "collect: " + err.Error()}
				}
			}
			outs[i], errs[i] = out, err
			if err != nil {
				cancel()
			}
		}
		if conc == 1 {
			run(i, is, ipath)
			if errs[i] != nil {
				return outs, errs[i]
			}
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, is *scope, ipath string) {
			defer wg.Done()
			defer func() { <-sem }()
			run(i, is, ipath)
		}(i, is, ipath)
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil && !isCancelled(err) {
			return outs, err
		}
	}
	for _, err := range errs {
		if err != nil {
			return outs, err
		}
	}
	if outs == nil {
		outs = []any{}
	}
	return outs, nil
}

func (r *runner) template(ctx context.Context, sc *scope, s *Step, path string, e Env) (any, error) {
	t := r.wf.Templates[s.Use]
	if t == nil {
		return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "no template " + s.Use}
	}
	with, err := Render(s.With, e)
	if err != nil {
		return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "with: " + err.Error()}
	}
	given, _ := with.(map[string]any)
	params, issues := ResolveInputs(t.Params, given)
	if HasErrors(issues) {
		return nil, &StepError{Path: path, Code: "invalid_argument", Message: "template " + s.Use + ": " + firstError(issues)}
	}
	ts := newScope(sc)
	ts.isolated = true
	ts.locals["params"] = params
	last, err := r.steps(ctx, ts, t.Steps, path, false)
	if err != nil {
		return nil, err
	}
	if t.Outputs != nil {
		out, err := Render(t.Outputs, r.env(ts, map[string]any{"result": last}))
		if err != nil {
			return nil, &StepError{Path: path, Code: "invalid_workflow", Message: "template outputs: " + err.Error()}
		}
		return out, nil
	}
	return last, nil
}

// ---- upsert ----

func (r *runner) upsert(ctx context.Context, sc *scope, s *Step, path string, rec *StepRecord) (any, error) {
	u := s.Upsert
	def := u.Define
	if u.Resource != "" {
		def = Presets[u.Resource].merge(u.Define)
	}
	bad := func(format string, a ...any) error {
		return &StepError{Path: path, Code: "invalid_workflow", Message: fmt.Sprintf(format, a...)}
	}
	e := r.env(sc, nil)
	renderMap := func(m any, env Env) (map[string]any, error) {
		if m == nil {
			return map[string]any{}, nil
		}
		if mm, ok := m.(map[string]any); ok && mm == nil {
			return map[string]any{}, nil
		}
		v, err := Render(m, env)
		if err != nil {
			return nil, err
		}
		switch x := v.(type) {
		case map[string]any:
			return x, nil
		case nil:
			return map[string]any{}, nil
		case *Unknown:
			return map[string]any{"$unknown": x}, nil
		}
		return nil, fmt.Errorf("must be an object, not %s", typeName(v))
	}
	with, err := renderMap(u.With, e)
	if err != nil {
		return nil, bad("with: %v", err)
	}
	// Developer resources name their organization; give them the run's.
	if strings.HasPrefix(firstCallAction(def), "developer.") {
		if _, ok := with["org"]; !ok {
			if d, ok := r.wf.Defaults.With["developer"]["org"]; ok {
				with["org"], _ = Render(d, e)
			} else if r.wf.Options.Org != "" {
				with["org"] = r.wf.Options.Org
			}
		}
	}
	paramsEnv := func(params map[string]any, extra map[string]any) Env {
		x := map[string]any{"params": params}
		for k, v := range extra {
			x[k] = v
		}
		return r.env(sc, x)
	}
	var match map[string]any
	if u.Match != nil {
		match, err = renderMap(map[string]any(u.Match), e)
	} else {
		match, err = renderMap(map[string]any(def.Match), paramsEnv(with, nil))
	}
	if err != nil {
		return nil, bad("match: %v", err)
	}
	base := mergeMaps(with, nil)
	for k, v := range match {
		if _, ok := base[k]; !ok && u.Match != nil {
			base[k] = v
		}
	}
	createParams, err := renderMap(u.CreateWith, e)
	if err != nil {
		return nil, bad("create_with: %v", err)
	}
	createParams = mergeMaps(base, createParams)
	updateParams, err := renderMap(u.UpdateWith, e)
	if err != nil {
		return nil, bad("update_with: %v", err)
	}
	updateParams = mergeMaps(base, updateParams)
	mode := firstNonEmpty(u.Mode, "upsert")
	r.setRequest(rec, map[string]any{"match": match, "with": with, "mode": mode}, s.Sensitive)
	plan := r.opts.Mode == ModePlan

	// find
	findWith, err := r.renderCallWith(def.Find, paramsEnv(base, nil))
	if err != nil {
		return nil, bad("find: %v", err)
	}
	if plan && (hasUnknown(findWith) || hasUnknown(match)) {
		r.setOperation(rec, "create_or_update")
		return map[string]any{"id": r.unknownID(s), "operation": &Unknown{Ref: "operation"}}, nil
	}
	found, err := r.find(ctx, path, def, findWith, match)
	if err != nil {
		return nil, err
	}
	idField := firstNonEmpty(def.RecordID, "id")
	out := map[string]any{"record": found}

	if found == nil {
		if mode == "update" {
			return nil, &StepError{Path: path, Code: "not_found", Message: "no " + firstNonEmpty(u.Resource, "resource") + " matches " + mustJSON(match)}
		}
		if def.Create == nil {
			return nil, bad("this resource cannot be created")
		}
		if plan {
			r.setOperation(rec, "would_create")
			out["operation"], out["created"], out["id"] = "would_create", true, r.unknownID(s)
			return out, nil
		}
		createWith, err := r.renderCallWith(def.Create, paramsEnv(createParams, nil))
		if err != nil {
			return nil, bad("create: %v", err)
		}
		res, err := r.call(ctx, path, def.Create.Action, createWith)
		if err != nil {
			return nil, err
		}
		id, err := r.resultID(def.Create, res, paramsEnv(createParams, map[string]any{"result": res}))
		if err != nil {
			return nil, bad("create id: %v", err)
		}
		r.setOperation(rec, "created")
		out["operation"], out["created"], out["id"], out["result"] = "created", true, id, res
		if def.Delete != nil && (u.Rollback == nil || *u.Rollback) {
			del, delEnv := def.Delete, paramsEnv(createParams, map[string]any{"id": id, "result": res})
			r.pushUndo(path, "delete "+firstNonEmpty(u.Resource, "resource")+" "+ToString(id), func(ctx context.Context) error {
				w, err := r.renderCallWith(del, delEnv)
				if err != nil {
					return err
				}
				_, err = r.call(ctx, "rollback."+path, del.Action, w)
				return err
			})
		}
		return out, nil
	}

	id, _ := index(found, idField, idField)
	out["id"], out["created"] = id, false
	if mode == "create" {
		return nil, &StepError{Path: path, Code: "already_exists", Message: firstNonEmpty(u.Resource, "resource") + " " + ToString(id) + " already exists"}
	}
	if mode == "ensure" || def.Update == nil {
		r.setOperation(rec, "unchanged")
		out["operation"] = "unchanged"
		return out, nil
	}
	if u.SkipUnchanged == nil || *u.SkipUnchanged {
		if same(found, updateParams, def.Compare) {
			r.setOperation(rec, "unchanged")
			out["operation"] = "unchanged"
			return out, nil
		}
	}
	if plan {
		r.setOperation(rec, "would_update")
		out["operation"] = "would_update"
		return out, nil
	}
	updateWith, err := r.renderCallWith(def.Update, paramsEnv(updateParams, map[string]any{"id": id, "found": found}))
	if err != nil {
		return nil, bad("update: %v", err)
	}
	res, err := r.call(ctx, path, def.Update.Action, updateWith)
	if err != nil {
		return nil, err
	}
	r.setOperation(rec, "updated")
	out["operation"], out["result"] = "updated", res
	return out, nil
}

func firstCallAction(def *ResourceDef) string {
	if def != nil && def.Find != nil {
		return def.Find.Action
	}
	return ""
}

func (r *runner) setOperation(rec *StepRecord, op string) {
	r.mu.Lock()
	rec.Operation = op
	r.mu.Unlock()
}

func (r *runner) renderCallWith(c *Call, e Env) (map[string]any, error) {
	if c == nil {
		return nil, fmt.Errorf("not defined")
	}
	return r.request(c.Action, c.With, e)
}

func (r *runner) resultID(c *Call, res any, e Env) (any, error) {
	if c.ID == "" {
		v, _ := index(res, "id", "id")
		return v, nil
	}
	if HasTemplate(c.ID) {
		return RenderString(c.ID, e)
	}
	return getPath(res, c.ID), nil
}

func getPath(v any, p string) any {
	cur := v
	for _, part := range strings.Split(p, ".") {
		if part == "" {
			continue
		}
		cur, _ = index(cur, part, p)
	}
	return cur
}

func (r *runner) find(ctx context.Context, path string, def *ResourceDef, with, match map[string]any) (any, error) {
	if def.Find.Item != "" {
		res, err := r.call(ctx, path, def.Find.Action, with)
		if err != nil {
			return nil, err
		}
		item := getPath(res, def.Find.Item)
		if item == nil || !matches(item, match) {
			return nil, nil
		}
		return item, nil
	}
	pg := def.Find.Page
	pages, limit := 1, 0
	limitField, offsetField := "limit", "offset"
	if pg != nil {
		pages, limit = 50, 200
		if pg.MaxPages > 0 {
			pages = pg.MaxPages
		}
		if pg.Limit > 0 {
			limit = pg.Limit
		}
		limitField, offsetField = firstNonEmpty(pg.LimitField, "limit"), firstNonEmpty(pg.OffsetField, "offset")
	}
	var hits []any
	for page := 0; page < pages; page++ {
		req := with
		if pg != nil {
			req = mergeMaps(with, map[string]any{limitField: float64(limit), offsetField: float64(page * limit)})
		}
		res, err := r.call(ctx, path, def.Find.Action, req)
		if err != nil {
			return nil, err
		}
		records := list(getPath(res, def.Find.Items))
		for _, rec := range records {
			if matches(rec, match) {
				hits = append(hits, rec)
			}
		}
		// A page may come back short when the action filters what it read,
		// so only an empty page (or a match) ends the search.
		if pg == nil || len(hits) > 0 || len(records) == 0 {
			break
		}
	}
	if len(hits) > 1 {
		r.event("warning", path, fmt.Sprintf("%d records match %s; using the first", len(hits), mustJSON(match)))
	}
	if len(hits) == 0 {
		return nil, nil
	}
	return hits[0], nil
}

// matches compares a record with a match: text ignoring case and spaces at
// the ends, the rest exactly.
func matches(rec any, match map[string]any) bool {
	for k, want := range match {
		have := getPath(rec, k)
		if !looseEqual(have, want) {
			return false
		}
	}
	return true
}

func looseEqual(have, want any) bool {
	if ws, ok := want.(string); ok {
		return strings.EqualFold(strings.TrimSpace(ToString(have)), strings.TrimSpace(ws))
	}
	return Equal(have, want)
}

// same reports whether a record already holds every value an update would
// send: the compare fields when the resource lists them, else every field
// but the ones that only say where the resource is. A field the record does
// not show counts as a change.
func same(rec any, params map[string]any, compare []string) bool {
	m, ok := rec.(map[string]any)
	if !ok {
		return false
	}
	keys := compare
	if keys == nil {
		for _, k := range sortedKeys(params) {
			if !routingField[k] {
				keys = append(keys, k)
			}
		}
	}
	for _, k := range keys {
		want, given := params[k]
		if !given {
			continue
		}
		have, ok := m[k]
		if !ok || !subsetEqual(want, have) {
			return false
		}
	}
	return true
}

// routingField names fields that say where a resource is, not what it is.
var routingField = map[string]bool{"org": true, "space": true, "room": true, "bot": true, "id": true, "kind": true, "status": true, "handle": true, "slug": true, "port": true}

func subsetEqual(want, have any) bool {
	wm, ok := want.(map[string]any)
	if !ok {
		if ws, ok := want.(string); ok {
			// Some records keep objects as JSON text.
			if hs, ok := have.(string); ok {
				return ws == hs
			}
		}
		if hs, ok := have.(string); ok {
			if _, isMap := want.(map[string]any); !isMap {
				return looseEqual(hs, ToString(want)) || Equal(want, have)
			}
		}
		return Equal(want, have)
	}
	hm, ok := have.(map[string]any)
	if !ok {
		if hs, ok := have.(string); ok {
			if parsed, err := builtins["from_json"].fn(nil, []any{hs}); err == nil {
				hm, _ = parsed.(map[string]any)
			}
		}
		if hm == nil {
			return false
		}
	}
	for k, v := range wm {
		if !subsetEqual(v, hm[k]) {
			return false
		}
	}
	return true
}

// ---- sandbox ----

const exitMarker = "__ASEMAN_WORKFLOW_EXIT="

var exitRe = regexp.MustCompile(`\n?` + exitMarker + `(\d+)\s*$`)

func (r *runner) sandbox(ctx context.Context, sc *scope, s *Step, path string, rec *StepRecord) (any, error) {
	b := s.Sandbox
	e := r.env(sc, nil)
	bad := func(format string, a ...any) error {
		return &StepError{Path: path, Code: "invalid_workflow", Message: fmt.Sprintf(format, a...)}
	}
	spaceV, err := RenderString(b.Space, e)
	if err != nil {
		return nil, bad("space: %v", err)
	}
	rootV, err := RenderString(b.Root, e)
	if err != nil {
		return nil, bad("root: %v", err)
	}
	space := ToString(spaceV)
	root := strings.Trim(pathpkg.Clean("/"+ToString(rootV)), "/")
	if root == "." {
		root = ""
	}
	abs := func(rel string) string { return pathpkg.Join("/workspace", root, rel) }

	// The files: the step's own, then the assets it copies.
	type file struct {
		path string
		text *string
		b64  string
		mode string
	}
	var files []file
	addFile := func(rel string, spec any, render bool) error {
		rel = strings.TrimPrefix(pathpkg.Clean("/"+rel), "/")
		if rel == "" || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("%q is not a file path inside the root", rel)
		}
		f := file{path: rel}
		switch x := spec.(type) {
		case string:
			text := x
			if render {
				v, err := RenderString(x, e)
				if err != nil {
					return fmt.Errorf("%s: %v", rel, err)
				}
				text = ToString(v)
			}
			f.text = &text
		case map[string]any:
			if raw, ok := x["$raw"]; ok {
				text := ToString(raw)
				f.text = &text
				break
			}
			f.mode = ToString(x["mode"])
			switch {
			case x["asset"] != nil:
				name := ToString(x["asset"])
				data, ok := r.blobs[name]
				if !ok {
					return fmt.Errorf("%s: no asset %q", rel, name)
				}
				if a := r.wf.Assets[name]; a.Template || Truthy(x["template"]) {
					v, err := RenderString(string(data), e)
					if err != nil {
						return fmt.Errorf("%s: %v", rel, err)
					}
					text := ToString(v)
					f.text = &text
				} else {
					f.b64 = base64.StdEncoding.EncodeToString(data)
				}
			case x["base64"] != nil:
				f.b64 = ToString(x["base64"])
			case x["json"] != nil:
				v := x["json"]
				if render {
					rv, err := Render(v, e)
					if err != nil {
						return fmt.Errorf("%s: %v", rel, err)
					}
					v = rv
				}
				text := mustJSONIndent(v)
				f.text = &text
			default:
				text := ToString(x["content"])
				if render || Truthy(x["template"]) {
					v, err := RenderString(text, e)
					if err != nil {
						return fmt.Errorf("%s: %v", rel, err)
					}
					text = ToString(v)
				}
				f.text = &text
			}
		default:
			text := ToString(spec)
			f.text = &text
		}
		files = append(files, f)
		return nil
	}
	for _, rel := range sortedKeys(b.Files) {
		if err := addFile(rel, b.Files[rel], b.Render); err != nil {
			return nil, bad("files: %v", err)
		}
	}
	if b.Assets != "" {
		names := make([]string, 0, len(r.wf.Assets))
		for name := range r.wf.Assets {
			if b.Assets == "*" || strings.HasPrefix(name, b.Assets) {
				names = append(names, name)
			}
		}
		sort.Strings(names)
		for _, name := range names {
			rel := name
			if b.Assets != "*" {
				rel = strings.TrimPrefix(name, b.Assets)
			}
			a := r.wf.Assets[name]
			if err := addFile(rel, map[string]any{"asset": name, "mode": a.Mode}, false); err != nil {
				return nil, bad("assets: %v", err)
			}
		}
	}

	// The commands.
	type command struct {
		run, workdir, expect string
		env                  map[string]any
		ignoreExit           bool
	}
	var cmds []command
	addCmd := func(v any) error {
		switch x := v.(type) {
		case string:
			cmds = append(cmds, command{run: x})
		case map[string]any:
			c := command{run: ToString(x["run"]), workdir: ToString(x["workdir"]), expect: ToString(x["expect"]), ignoreExit: Truthy(x["ignore_exit"])}
			if env, ok := x["env"].(map[string]any); ok {
				c.env = env
			}
			if c.run == "" {
				return fmt.Errorf("a command needs run")
			}
			cmds = append(cmds, c)
		default:
			return fmt.Errorf("a command is text or {run, workdir, env, expect, ignore_exit}")
		}
		return nil
	}
	execV, err := Render(b.Exec, e)
	if err != nil {
		return nil, bad("exec: %v", err)
	}
	switch x := execV.(type) {
	case nil:
	case []any:
		for _, c := range x {
			if err := addCmd(c); err != nil {
				return nil, bad("exec: %v", err)
			}
		}
	default:
		if err := addCmd(x); err != nil {
			return nil, bad("exec: %v", err)
		}
	}
	envV, err := Render(b.Env, e)
	if err != nil {
		return nil, bad("env: %v", err)
	}
	baseEnv, _ := envV.(map[string]any)
	workdirV, err := RenderString(b.Workdir, e)
	if err != nil {
		return nil, bad("workdir: %v", err)
	}
	proxyV, err := Render(b.Proxy, e)
	if err != nil {
		return nil, bad("proxy: %v", err)
	}
	proxy, _ := proxyV.(map[string]any)
	if len(proxy) == 0 {
		proxy = nil
	}

	listed := make([]any, 0, len(files))
	total := 0
	for _, f := range files {
		listed = append(listed, f.path)
		if f.text != nil {
			total += len(*f.text)
		} else {
			total += base64.StdEncoding.DecodedLen(len(f.b64))
		}
	}
	commands := make([]any, 0, len(cmds))
	for _, c := range cmds {
		commands = append(commands, c.run)
	}
	request := map[string]any{"space": space, "root": "/workspace/" + root, "files": listed, "bytes": float64(total), "commands": commands, "start": b.Start, "clean": b.Clean}
	if proxy != nil {
		request["proxy"] = proxy
	}
	r.setRequest(rec, request, s.Sensitive)
	out := map[string]any{"space": space, "root": "/workspace/" + root, "files": listed}
	if r.opts.Mode == ModePlan {
		out["commands"] = commands
		if proxy != nil {
			out["proxy"] = &Unknown{Ref: "proxy"}
		}
		return out, nil
	}
	if space == "" {
		return nil, bad("space is empty")
	}

	if b.Start {
		r.event("info", path, "waking the computer of space "+space)
		if _, err := r.call(ctx, path, "spaces.sandbox_start", map[string]any{"space": space}); err != nil {
			return nil, err
		}
		deadline := r.opts.Now().Add(5 * time.Minute)
		for {
			st, err := r.call(ctx, path, "spaces.sandbox_status", map[string]any{"space": space})
			if err != nil {
				return nil, err
			}
			if ToString(getPath(st, "status")) == "running" {
				break
			}
			if r.opts.Now().After(deadline) {
				return nil, &StepError{Path: path, Code: "timeout", Message: "the computer did not start within 5m"}
			}
			if err := r.opts.Sleep(ctx, 3*time.Second); err != nil {
				return nil, err
			}
		}
	}
	if b.Clean && root != "" {
		if _, err := r.fileOp(ctx, path, space, map[string]any{"operation": "delete", "path": abs("")}, true); err != nil {
			return nil, err
		}
	}
	modes := map[string]string{}
	for i, f := range files {
		req := map[string]any{"space": space, "operation": "write", "path": abs(f.path), "wake": true}
		if f.text != nil {
			req["content"] = *f.text
		} else {
			req["data_base64"] = f.b64
		}
		if _, err := r.fileOp(ctx, path, space, req, false); err != nil {
			return nil, err
		}
		if f.mode != "" {
			modes[abs(f.path)] = f.mode
		}
		if (i+1)%25 == 0 {
			r.event("info", path, fmt.Sprintf("wrote %d of %d files", i+1, len(files)))
		}
	}
	if len(files) > 0 {
		r.event("info", path, fmt.Sprintf("wrote %d file(s) (%d bytes) under /workspace/%s", len(files), total, root))
	}
	if len(modes) > 0 {
		var chmod []string
		for _, p := range sortedKeysString(modes) {
			if !regexp.MustCompile(`^[0-7]{3,4}$`).MatchString(modes[p]) {
				return nil, bad("mode %q of %s is not octal", modes[p], p)
			}
			chmod = append(chmod, "chmod "+modes[p]+" "+shellQuote(p))
		}
		cmds = append([]command{{run: strings.Join(chmod, " && "), workdir: "/workspace"}}, cmds...)
	}
	results := []any{}
	for _, c := range cmds {
		dir := firstNonEmpty(c.workdir, ToString(workdirV))
		if dir == "" {
			dir = "/workspace/" + root
		} else if !strings.HasPrefix(dir, "/") {
			dir = pathpkg.Join("/workspace", root, dir)
		}
		var script strings.Builder
		script.WriteString("mkdir -p " + shellQuote(dir) + " && cd " + shellQuote(dir) + " && ")
		envs := mergeMaps(baseEnv, c.env)
		for _, k := range sortedKeys(envs) {
			if !idRe.MatchString(k) {
				return nil, bad("env name %q", k)
			}
			script.WriteString("export " + k + "=" + shellQuote(ToString(envs[k])) + " && ")
		}
		script.WriteString("{ " + c.run + "\n} 2>&1; echo \"" + exitMarker + "$?\"")
		res, err := r.call(ctx, path, "spaces.sandbox_exec", map[string]any{"space": space, "command": script.String()})
		if err != nil {
			return nil, err
		}
		output := ToString(getPath(res, "output"))
		code := -1
		if m := exitRe.FindStringSubmatch(output); m != nil {
			code, _ = strconv.Atoi(m[1])
			output = exitRe.ReplaceAllString(output, "")
		}
		results = append(results, map[string]any{"command": c.run, "exit_code": float64(code), "output": clipText(output, 16000)})
		r.event("info", path, fmt.Sprintf("$ %s → exit %d", clipText(c.run, 200), code))
		if code != 0 && code != -1 && !c.ignoreExit {
			return nil, &StepError{Path: path, Code: "failed", Message: fmt.Sprintf("`%s` exited %d: %s", clipText(c.run, 200), code, tail(output, 1500))}
		}
		expect := firstNonEmpty(c.expect, b.Expect)
		if expect != "" && !strings.Contains(output, expect) {
			return nil, &StepError{Path: path, Code: "assertion", Message: fmt.Sprintf("`%s` did not print %q: %s", clipText(c.run, 200), expect, tail(output, 1500))}
		}
	}
	out["commands"] = results
	if proxy != nil {
		req := mergeMaps(map[string]any{"space": space}, proxy)
		existing, err := r.call(ctx, path, "spaces.proxy_list", map[string]any{"space": space})
		if err != nil {
			return nil, err
		}
		var hit any
		for _, p := range list(getPath(existing, "proxies")) {
			if looseEqual(getPath(p, "port"), req["port"]) {
				hit = p
			}
		}
		if hit != nil && !Truthy(req["replace"]) {
			out["proxy"] = mergeMaps(hit.(map[string]any), map[string]any{"proxy_id": getPath(hit, "id"), "operation": "unchanged"})
		} else {
			if hit != nil {
				if _, err := r.call(ctx, path, "spaces.proxy_delete", map[string]any{"proxy": getPath(hit, "id")}); err != nil {
					return nil, err
				}
			}
			delete(req, "replace")
			res, err := r.call(ctx, path, "spaces.proxy_create", req)
			if err != nil {
				return nil, err
			}
			if m, ok := res.(map[string]any); ok {
				out["proxy"] = mergeMaps(m, map[string]any{"operation": "created"})
				if hit == nil {
					pid := m["proxy_id"]
					r.pushUndo(path, "delete proxy "+ToString(pid), func(ctx context.Context) error {
						_, err := r.call(ctx, "rollback."+path, "spaces.proxy_delete", map[string]any{"proxy": pid})
						return err
					})
				}
			} else {
				out["proxy"] = res
			}
		}
	}
	return out, nil
}

func (r *runner) fileOp(ctx context.Context, path, space string, req map[string]any, tolerateMissing bool) (any, error) {
	res, err := r.call(ctx, path, "spaces.sandbox_files", req)
	if err != nil {
		return nil, err
	}
	if m, ok := res.(map[string]any); ok {
		if okv, has := m["ok"]; has && !Truthy(okv) {
			if tolerateMissing && Truthy(m["missing"]) {
				return res, nil
			}
			return nil, &StepError{Path: path, Code: "unavailable", Message: ToString(req["operation"]) + " " + ToString(req["path"]) + ": " + ToString(m["error"])}
		}
	}
	return res, nil
}

func sortedKeysString(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'" }

func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}

func mustJSONIndent(v any) string {
	out, _ := builtins["json"].fn(nil, []any{v, true})
	return ToString(out) + "\n"
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// ---- redaction & clipping ----

type redactor struct{ secrets []string }

func newRedactor(values []string) *redactor {
	var keep []string
	for _, v := range values {
		if len(v) >= 4 {
			keep = append(keep, v)
		}
	}
	sort.Slice(keep, func(i, j int) bool { return len(keep[i]) > len(keep[j]) })
	return &redactor{secrets: keep}
}

const redacted = "••••••"

// HasRedacted reports whether a stored value had something hidden in it.
func HasRedacted(v any) bool {
	switch x := v.(type) {
	case string:
		return strings.Contains(x, redacted)
	case []any:
		for _, e := range x {
			if HasRedacted(e) {
				return true
			}
		}
	case map[string]any:
		for _, e := range x {
			if HasRedacted(e) {
				return true
			}
		}
	}
	return false
}

var sensitiveKey = regexp.MustCompile(`(?i)(^|_)(secret|password|passwd|token|api_?key|private_?key|credentials?)$`)

func (r *redactor) text(s string) string {
	for _, v := range r.secrets {
		s = strings.ReplaceAll(s, v, redacted)
	}
	return s
}

// value is a copy of v fit to store: secrets and sensitive fields hidden,
// long texts clipped, deep values cut.
func (r *redactor) value(v any, depth int) any {
	if depth > 12 {
		return "…"
	}
	switch x := v.(type) {
	case string:
		return clipText(r.text(x), 4096)
	case *Unknown:
		return x.String()
	case *Lambda:
		return "<lambda>"
	case []any:
		n := len(x)
		limit := min(n, 200)
		out := make([]any, 0, limit+1)
		for _, e := range x[:limit] {
			out = append(out, r.value(e, depth+1))
		}
		if n > limit {
			out = append(out, fmt.Sprintf("… %d more", n-limit))
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			if sensitiveKey.MatchString(k) {
				if s, ok := e.(string); ok && s != "" {
					out[k] = redacted
					continue
				}
			}
			out[k] = r.value(e, depth+1)
		}
		return out
	}
	return v
}

func clipText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + fmt.Sprintf("… (%d bytes)", len(s))
}
