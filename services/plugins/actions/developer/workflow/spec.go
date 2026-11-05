// Package workflow is the developer API's workflow installer: one JSON
// document that describes, in order, everything an organization needs — its
// platform, keys, spaces, agents, apps, the source code of a full-stack app
// written onto a space's computer, the commands that build and start it, the
// previews that serve it — and an engine that validates, plans (dry-runs)
// and runs it against any action of the platform.
//
// The engine knows nothing of Aseman itself: it calls actions through a
// [Caller], which the developer namespace binds to the node (as the person,
// or as the person behind an API key). See docs/WORKFLOWS.md for the format.
package workflow

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// FormatVersion is the workflow format this engine runs.
const FormatVersion = "1"

// Limits of one workflow.
const (
	MaxDocumentBytes  = 48 << 20
	MaxSteps          = 5000 // executed, counting every loop iteration
	MaxDepth          = 24   // groups, loops and templates inside each other
	MaxConcurrency    = 16
	MaxAttempts       = 20
	DefaultRunTimeout = time.Hour
	MaxRunTimeout     = 6 * time.Hour
)

// Workflow is a whole installer document.
type Workflow struct {
	Schema      string               `json:"$schema,omitempty"`
	Format      string               `json:"aseman_workflow"`
	Name        string               `json:"name"`
	Description string               `json:"description,omitempty"`
	Version     string               `json:"version,omitempty"`
	Inputs      map[string]InputSpec `json:"inputs,omitempty"`
	Secrets     SecretSpecs          `json:"secrets,omitempty"`
	// Vars are computed once, before the steps, in dependency order.
	Vars      map[string]any       `json:"vars,omitempty"`
	Defaults  StepDefaults         `json:"defaults,omitempty"`
	Options   Settings             `json:"options,omitempty"`
	Assets    map[string]Asset     `json:"assets,omitempty"`
	Templates map[string]*Template `json:"templates,omitempty"`
	Steps     []*Step              `json:"steps"`
	// OnFailure runs when the workflow fails (after any rollback).
	OnFailure []*Step `json:"on_failure,omitempty"`
	// Finally runs at the end, whatever happened.
	Finally []*Step        `json:"finally,omitempty"`
	Outputs map[string]any `json:"outputs,omitempty"`
}

// InputSpec declares one input a run gives.
type InputSpec struct {
	Type        string   `json:"type,omitempty"` // string, number, integer, boolean, object, list, any
	Description string   `json:"description,omitempty"`
	Default     any      `json:"default,omitempty"`
	Required    bool     `json:"required,omitempty"`
	Enum        []any    `json:"enum,omitempty"`
	Pattern     string   `json:"pattern,omitempty"`
	Min         *float64 `json:"min,omitempty"`
	Max         *float64 `json:"max,omitempty"`
	// Sensitive inputs are redacted from the stored run like secrets.
	Sensitive bool `json:"sensitive,omitempty"`
}

// SecretSpec declares a secret a run gives (never stored).
type SecretSpec struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Required    bool   `json:"required,omitempty"`
}

// SecretSpecs reads ["A", "B"], [{name, …}] or {"A": {…}}.
type SecretSpecs []SecretSpec

func (s *SecretSpecs) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) > 0 && b[0] == '{' {
		var m map[string]SecretSpec
		if err := json.Unmarshal(b, &m); err != nil {
			return err
		}
		names := make([]string, 0, len(m))
		for k := range m {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, n := range names {
			spec := m[n]
			spec.Name = n
			*s = append(*s, spec)
		}
		return nil
	}
	var raw []json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	for _, r := range raw {
		var name string
		if json.Unmarshal(r, &name) == nil {
			*s = append(*s, SecretSpec{Name: name, Required: true})
			continue
		}
		var spec SecretSpec
		if err := json.Unmarshal(r, &spec); err != nil {
			return err
		}
		*s = append(*s, spec)
	}
	return nil
}

// StepDefaults apply to every step that does not say otherwise.
type StepDefaults struct {
	Retry           *Retry    `json:"retry,omitempty"`
	Timeout         *Duration `json:"timeout,omitempty"`
	ContinueOnError bool      `json:"continue_on_error,omitempty"`
	// With is merged into the request of every action whose namespace is a
	// key, e.g. {"developer": {"org": "…"}}.
	With map[string]map[string]any `json:"with,omitempty"`
}

// Settings shape the whole run (the document's "options").
type Settings struct {
	// RollbackOnFailure undoes, newest first, what the run made: the
	// compensate steps of steps that succeeded, and the resources upserts
	// created.
	RollbackOnFailure bool      `json:"rollback_on_failure,omitempty"`
	Timeout           *Duration `json:"timeout,omitempty"`
	MaxSteps          int       `json:"max_steps,omitempty"`
	// Org is the developer organization developer.* steps use when they name
	// none ("personal" or an id; the API key's own on the developer host).
	Org string `json:"org,omitempty"`
	// StampPlatform makes what the run creates (spaces, agents, apps) part
	// of the organization's sub-platform, as the developer host does for a
	// key. Runs on the developer host always do.
	StampPlatform bool `json:"stamp_platform,omitempty"`
}

// Asset is a file the document carries: text, base64 bytes, or JSON.
type Asset struct {
	Content  *string `json:"content,omitempty"`
	Base64   string  `json:"base64,omitempty"`
	JSON     any     `json:"json,omitempty"`
	Mime     string  `json:"mime,omitempty"`
	Template bool    `json:"template,omitempty"`
	// Mode is a file mode for the sandbox, e.g. "0755".
	Mode string `json:"mode,omitempty"`
}

func (a *Asset) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) > 0 && b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		a.Content = &s
		return nil
	}
	type plain Asset
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	*a = Asset(p)
	return nil
}

// Template is a reusable group of steps with parameters.
type Template struct {
	Description string               `json:"description,omitempty"`
	Params      map[string]InputSpec `json:"params,omitempty"`
	Steps       []*Step              `json:"steps"`
	Outputs     any                  `json:"outputs,omitempty"`
}

// Duration reads "90s", "5m", "1h30m" or a number of seconds.
type Duration struct{ time.Duration }

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	parsed, err := ParseDuration(v)
	if err != nil {
		return err
	}
	d.Duration = parsed
	return nil
}

func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

// ParseDuration reads a duration from text or seconds.
func ParseDuration(v any) (time.Duration, error) {
	switch x := v.(type) {
	case float64:
		return time.Duration(x * float64(time.Second)), nil
	case string:
		x = strings.TrimSpace(x)
		if f, err := strconv.ParseFloat(x, 64); err == nil {
			return time.Duration(f * float64(time.Second)), nil
		}
		d, err := time.ParseDuration(x)
		if err != nil {
			return 0, fmt.Errorf("bad duration %q (use 30s, 5m, 1h)", x)
		}
		return d, nil
	case nil:
		return 0, nil
	}
	return 0, fmt.Errorf("bad duration %v", v)
}

// Retry repeats a failing step.
type Retry struct {
	Attempts int       `json:"attempts"`
	Delay    *Duration `json:"delay,omitempty"`
	Backoff  float64   `json:"backoff,omitempty"`
	MaxDelay *Duration `json:"max_delay,omitempty"`
	// On limits retries to these error codes (not_found, invalid_argument,
	// conflict, permission, unavailable, finance, timeout, internal, …).
	// Empty: everything but invalid_argument, permission and not_found.
	On []string `json:"on,omitempty"`
}

// Step is one unit of a workflow. Exactly one of the kinds is set.
type Step struct {
	ID          string `json:"id,omitempty"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
	If          any    `json:"if,omitempty"`

	// Kinds.
	Action   string         `json:"action,omitempty"`
	With     any            `json:"with,omitempty"`
	Upsert   *Upsert        `json:"upsert,omitempty"`
	Model    *ModelStep     `json:"model,omitempty"`
	Sandbox  *SandboxStep   `json:"sandbox,omitempty"`
	Wait     *WaitStep      `json:"wait,omitempty"`
	Set      map[string]any `json:"set,omitempty"`
	Assert   any            `json:"assert,omitempty"`
	Log      any            `json:"log,omitempty"`
	Sleep    *Duration      `json:"sleep,omitempty"`
	Fail     any            `json:"fail,omitempty"`
	Steps    []*Step        `json:"steps,omitempty"`
	Parallel bool           `json:"parallel,omitempty"`
	Use      string         `json:"use,omitempty"` // a template

	// Loop: the step (whatever its kind) runs once per item.
	ForEach     any    `json:"for_each,omitempty"`
	As          string `json:"as,omitempty"`
	IndexAs     string `json:"index_as,omitempty"`
	Concurrency int    `json:"concurrency,omitempty"`
	// Collect is what each iteration adds to the loop's outputs (default:
	// the iteration's last output).
	Collect any `json:"collect,omitempty"`

	// Behaviour.
	Retry           *Retry    `json:"retry,omitempty"`
	Timeout         *Duration `json:"timeout,omitempty"`
	ContinueOnError bool      `json:"continue_on_error,omitempty"`
	OnError         []*Step   `json:"on_error,omitempty"`
	// Compensate undoes this step when the run rolls back.
	Compensate *Step `json:"compensate,omitempty"`
	// Outputs reshapes what the step answers (with `result` in scope).
	Outputs any `json:"outputs,omitempty"`
	// Export sets workflow vars from the result.
	Export map[string]any `json:"export,omitempty"`
	// Sensitive keeps the step's request and outputs out of the stored run.
	Sensitive bool `json:"sensitive,omitempty"`
	// Plan "run" makes a plan run this (read-only) step for real.
	Plan string `json:"plan,omitempty"`
}

// Upsert finds a resource and creates or updates it.
type Upsert struct {
	// Resource is a built-in kind (see Presets); Define writes one.
	Resource   string         `json:"resource,omitempty"`
	Define     *ResourceDef   `json:"define,omitempty"`
	Match      map[string]any `json:"match,omitempty"`
	With       any            `json:"with,omitempty"`
	CreateWith any            `json:"create_with,omitempty"`
	UpdateWith any            `json:"update_with,omitempty"`
	// Mode: "upsert" (default), "ensure" (create when missing, never
	// update), "update" (it must exist), "create" (it must not).
	Mode string `json:"mode,omitempty"`
	// SkipUnchanged (default true) skips the update when every field the
	// update would send already has that value.
	SkipUnchanged *bool `json:"skip_unchanged,omitempty"`
	// Rollback (default true) deletes what this upsert created when the run
	// rolls back.
	Rollback *bool `json:"rollback,omitempty"`
}

// ResourceDef is how a kind of resource is found, created, updated, deleted.
type ResourceDef struct {
	Find   *Call `json:"find,omitempty"`
	Create *Call `json:"create,omitempty"`
	Update *Call `json:"update,omitempty"`
	Delete *Call `json:"delete,omitempty"`
	// Match is the default match (expressions over `params`).
	Match map[string]any `json:"match,omitempty"`
	// RecordID is the id field of a found record (default "id").
	RecordID string `json:"record_id,omitempty"`
	// Compare lists the fields skip_unchanged compares (default: every
	// field the update sends that the record has).
	Compare []string `json:"compare,omitempty"`
}

// Call is one action call of a resource.
type Call struct {
	Action string `json:"action"`
	With   any    `json:"with,omitempty"`
	// Items is the path of the list of records in a find's answer; Item the
	// path of a single record (a singleton, null when there is none).
	Items string `json:"items,omitempty"`
	Item  string `json:"item,omitempty"`
	// ID is the path of the new resource's id in a create's answer.
	ID string `json:"id,omitempty"`
	// Page makes a find read page after page until it finds a match or a
	// page comes back empty.
	Page *Page `json:"page,omitempty"`
}

// Page is how a find pages through a list action.
type Page struct {
	Limit       int    `json:"limit,omitempty"`        // default 200
	MaxPages    int    `json:"max_pages,omitempty"`    // default 50
	LimitField  string `json:"limit_field,omitempty"`  // default "limit"
	OffsetField string `json:"offset_field,omitempty"` // default "offset"
}

// ModelStep calls a model through the developer API's router.
type ModelStep struct {
	// Type: chat (default), embeddings, image, speech, transcription,
	// rerank, decision.
	Type string `json:"type,omitempty"`
	// Body is the OpenAI-shaped request (model, messages, provider, …).
	Body any `json:"body"`
}

// SandboxStep installs and runs software on a space's computer.
type SandboxStep struct {
	Space string `json:"space"`
	// Start wakes the computer first and waits until it runs.
	Start bool `json:"start,omitempty"`
	// Root is the folder under /workspace the files go in.
	Root string `json:"root,omitempty"`
	// Clean empties Root first.
	Clean bool `json:"clean,omitempty"`
	// Files maps paths (under Root) to text, {content|base64|json|asset}.
	Files map[string]any `json:"files,omitempty"`
	// Assets copies the document's assets under this prefix ("" none, "*" all).
	Assets string `json:"assets,omitempty"`
	// Render renders ${{ }} inside the files' text (off by default).
	Render bool `json:"render,omitempty"`
	// Exec runs commands, in order, after the files are written.
	Exec any `json:"exec,omitempty"`
	// Workdir is where commands run (default: Root).
	Workdir string `json:"workdir,omitempty"`
	// Env is exported to the commands.
	Env map[string]any `json:"env,omitempty"`
	// Proxy serves a port of the computer (spaces.proxy_create).
	Proxy map[string]any `json:"proxy,omitempty"`
	// Expect fails the step when a command's output does not contain it.
	Expect string `json:"expect,omitempty"`
}

// WaitStep polls an action until a condition holds.
type WaitStep struct {
	Action   string    `json:"action"`
	With     any       `json:"with,omitempty"`
	Until    any       `json:"until"`
	Interval *Duration `json:"interval,omitempty"`
	Timeout  *Duration `json:"timeout,omitempty"`
}

// Kind is the step's kind.
func (s *Step) Kind() string {
	kinds := s.kinds()
	if len(kinds) == 1 {
		return kinds[0]
	}
	return ""
}

func (s *Step) kinds() []string {
	var k []string
	add := func(on bool, name string) {
		if on {
			k = append(k, name)
		}
	}
	add(s.Action != "", "action")
	add(s.Upsert != nil, "upsert")
	add(s.Model != nil, "model")
	add(s.Sandbox != nil, "sandbox")
	add(s.Wait != nil, "wait")
	add(s.Set != nil, "set")
	add(s.Assert != nil, "assert")
	add(s.Log != nil, "log")
	add(s.Sleep != nil, "sleep")
	add(s.Fail != nil, "fail")
	add(s.Steps != nil, "group")
	add(s.Use != "", "template")
	return k
}

// Decode reads a workflow document. Unknown fields are refused, so a typo is
// an error rather than a silently ignored setting.
func Decode(raw []byte) (*Workflow, error) {
	if len(raw) > MaxDocumentBytes {
		return nil, fmt.Errorf("the workflow is larger than %d MB", MaxDocumentBytes>>20)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	var wf Workflow
	if err := dec.Decode(&wf); err != nil {
		return nil, fmt.Errorf("the workflow is not valid JSON for this format: %v", err)
	}
	normalizeNumbers(&wf)
	return &wf, nil
}

// normalizeNumbers turns json.Number into float64 throughout the free-form
// values, so expressions see plain numbers.
func normalizeNumbers(wf *Workflow) {
	var steps func([]*Step)
	fix := func(v any) any { return plainNumbers(v) }
	fixMap := func(m map[string]any) map[string]any {
		if m == nil {
			return nil
		}
		return fix(m).(map[string]any)
	}
	var one func(s *Step)
	one = func(s *Step) {
		if s == nil {
			return
		}
		s.If, s.With, s.Assert, s.Log, s.Fail, s.ForEach, s.Collect, s.Outputs = fix(s.If), fix(s.With), fix(s.Assert), fix(s.Log), fix(s.Fail), fix(s.ForEach), fix(s.Collect), fix(s.Outputs)
		s.Set, s.Export = fixMap(s.Set), fixMap(s.Export)
		if u := s.Upsert; u != nil {
			u.Match, u.With, u.CreateWith, u.UpdateWith = fixMap(u.Match), fix(u.With), fix(u.CreateWith), fix(u.UpdateWith)
			if d := u.Define; d != nil {
				d.Match = fixMap(d.Match)
				for _, c := range []*Call{d.Find, d.Create, d.Update, d.Delete} {
					if c != nil {
						c.With = fix(c.With)
					}
				}
			}
		}
		if m := s.Model; m != nil {
			m.Body = fix(m.Body)
		}
		if b := s.Sandbox; b != nil {
			b.Files, b.Env, b.Proxy, b.Exec = fixMap(b.Files), fixMap(b.Env), fixMap(b.Proxy), fix(b.Exec)
		}
		if w := s.Wait; w != nil {
			w.With, w.Until = fix(w.With), fix(w.Until)
		}
		steps(s.Steps)
		steps(s.OnError)
		one(s.Compensate)
	}
	steps = func(list []*Step) {
		for _, s := range list {
			one(s)
		}
	}
	steps(wf.Steps)
	steps(wf.OnFailure)
	steps(wf.Finally)
	for _, t := range wf.Templates {
		if t != nil {
			steps(t.Steps)
			t.Outputs = fix(t.Outputs)
			for k, p := range t.Params {
				p.Default = fix(p.Default)
				t.Params[k] = p
			}
		}
	}
	wf.Vars, wf.Outputs = fixMap(wf.Vars), fixMap(wf.Outputs)
	for k, in := range wf.Inputs {
		in.Default = fix(in.Default)
		for i, e := range in.Enum {
			in.Enum[i] = fix(e)
		}
		wf.Inputs[k] = in
	}
	for k, a := range wf.Assets {
		a.JSON = fix(a.JSON)
		wf.Assets[k] = a
	}
	for ns, m := range wf.Defaults.With {
		wf.Defaults.With[ns] = fixMap(m)
	}
}

func plainNumbers(v any) any {
	switch x := v.(type) {
	case json.Number:
		f, _ := x.Float64()
		return f
	case []any:
		for i, e := range x {
			x[i] = plainNumbers(e)
		}
		return x
	case map[string]any:
		for k, e := range x {
			x[k] = plainNumbers(e)
		}
		return x
	}
	return v
}

// ---- validation ----

// Issue is one problem the validator found.
type Issue struct {
	Path     string `json:"path"`
	Message  string `json:"message"`
	Severity string `json:"severity"` // error | warning
}

// Catalog tells the validator which actions exist.
type Catalog interface {
	// ActionExists reports whether "namespace.action" may be called; a
	// reason explains a refusal.
	ActionExists(name string) (ok bool, reason string)
}

var idRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

var knownInputTypes = map[string]bool{"": true, "string": true, "number": true, "integer": true, "boolean": true, "object": true, "list": true, "array": true, "any": true}

var modelTypes = map[string]bool{"": true, "chat": true, "embeddings": true, "image": true, "speech": true, "transcription": true, "rerank": true, "decision": true}

type validator struct {
	wf     *Workflow
	cat    Catalog
	issues []Issue
	ids    map[string]string // id → path where declared
	allIDs map[string]bool
	refs   []ref
	depth  int
}

func (v *validator) errf(path, format string, a ...any) {
	v.issues = append(v.issues, Issue{Path: path, Message: fmt.Sprintf(format, a...), Severity: "error"})
}
func (v *validator) warnf(path, format string, a ...any) {
	v.issues = append(v.issues, Issue{Path: path, Message: fmt.Sprintf(format, a...), Severity: "warning"})
}

// Validate checks a workflow without running anything. A nil catalog skips
// the check that actions exist.
func Validate(wf *Workflow, cat Catalog) []Issue {
	v := &validator{wf: wf, cat: cat, ids: map[string]string{}}
	if wf.Format != FormatVersion {
		v.errf("aseman_workflow", "must be %q (the format version)", FormatVersion)
	}
	if strings.TrimSpace(wf.Name) == "" {
		v.errf("name", "a workflow needs a name")
	}
	if len(wf.Steps) == 0 {
		v.errf("steps", "a workflow needs at least one step")
	}
	for name, in := range wf.Inputs {
		p := "inputs." + name
		if !idRe.MatchString(name) {
			v.errf(p, "an input name is letters, digits and _")
		}
		v.checkInput(p, in)
	}
	seen := map[string]bool{}
	for i, s := range wf.Secrets {
		p := fmt.Sprintf("secrets[%d]", i)
		if !idRe.MatchString(s.Name) {
			v.errf(p, "a secret name is letters, digits and _")
		}
		if seen[s.Name] {
			v.errf(p, "secret %s is declared twice", s.Name)
		}
		seen[s.Name] = true
	}
	for name := range wf.Vars {
		if !idRe.MatchString(name) {
			v.errf("vars."+name, "a var name is letters, digits and _")
		}
	}
	if _, err := varOrder(wf.Vars); err != nil {
		v.errf("vars", "%v", err)
	}
	v.exprs("vars", wf.Vars)
	if d := wf.Defaults.Retry; d != nil {
		v.checkRetry("defaults.retry", d)
	}
	if t := wf.Options.Timeout; t != nil && (t.Duration <= 0 || t.Duration > MaxRunTimeout) {
		v.errf("options.timeout", "must be between 1s and %s", MaxRunTimeout)
	}
	if wf.Options.MaxSteps < 0 || wf.Options.MaxSteps > MaxSteps {
		v.errf("options.max_steps", "must be between 1 and %d", MaxSteps)
	}
	for name, a := range wf.Assets {
		p := "assets." + name
		set := 0
		if a.Content != nil {
			set++
		}
		if a.Base64 != "" {
			set++
		}
		if a.JSON != nil {
			set++
		}
		if set != 1 {
			v.errf(p, "an asset is one of content, base64 or json")
		}
		if strings.Contains(name, "..") || strings.HasPrefix(name, "/") {
			v.errf(p, "an asset path is relative and stays inside its folder")
		}
	}
	for name, t := range wf.Templates {
		p := "templates." + name
		if !idRe.MatchString(name) {
			v.errf(p, "a template name is letters, digits and _")
		}
		if t == nil || len(t.Steps) == 0 {
			v.errf(p, "a template needs steps")
			continue
		}
		for pn, ps := range t.Params {
			v.checkInput(p+".params."+pn, ps)
		}
		saved := v.ids
		v.ids = map[string]string{}
		v.steps(p+".steps", t.Steps)
		v.ids = saved
	}
	v.steps("steps", wf.Steps)
	v.steps("on_failure", wf.OnFailure)
	v.steps("finally", wf.Finally)
	v.exprs("outputs", wf.Outputs)
	v.checkRefs()
	sort.SliceStable(v.issues, func(i, j int) bool { return v.issues[i].Severity == "error" && v.issues[j].Severity != "error" })
	return v.issues
}

// HasErrors reports whether any issue is an error.
func HasErrors(issues []Issue) bool {
	for _, i := range issues {
		if i.Severity == "error" {
			return true
		}
	}
	return false
}

func (v *validator) checkInput(p string, in InputSpec) {
	if !knownInputTypes[in.Type] {
		v.errf(p+".type", "unknown type %q", in.Type)
	}
	if in.Pattern != "" {
		if _, err := regexp.Compile(in.Pattern); err != nil {
			v.errf(p+".pattern", "bad pattern: %v", err)
		}
	}
	if in.Default != nil {
		if err := checkValue(in, in.Default); err != nil {
			v.errf(p+".default", "%v", err)
		}
	}
}

func (v *validator) checkRetry(p string, r *Retry) {
	if r.Attempts < 1 || r.Attempts > MaxAttempts {
		v.errf(p+".attempts", "must be between 1 and %d", MaxAttempts)
	}
	if r.Backoff != 0 && (r.Backoff < 1 || r.Backoff > 10) {
		v.errf(p+".backoff", "must be between 1 and 10")
	}
}

// refs collected for the second pass: steps.<id> must be declared somewhere.
type ref struct{ path, id string }

func (v *validator) exprs(path string, val any) {
	expressionsIn(val, path, func(p, src string, e *Expr, err error) {
		if err != nil {
			v.errf(p, "%v", err)
			return
		}
		v.noteRefs(p, e)
	})
}

func (v *validator) cond(path string, val any) {
	if s, ok := val.(string); ok && !HasTemplate(s) {
		e, err := Parse(s)
		if err != nil {
			v.errf(path, "%v", err)
			return
		}
		v.noteRefs(path, e)
		return
	}
	v.exprs(path, val)
}

func (v *validator) noteRefs(path string, e *Expr) {
	for _, r := range e.Refs() {
		if len(r) >= 2 && r[0] == "steps" {
			v.refs = append(v.refs, ref{path: path, id: r[1]})
		}
		if len(r) >= 2 && r[0] == "secrets" {
			found := false
			for _, s := range v.wf.Secrets {
				found = found || s.Name == r[1]
			}
			if !found {
				v.warnf(path, "secrets.%s is not declared in secrets", r[1])
			}
		}
		if len(r) >= 2 && r[0] == "inputs" {
			if _, ok := v.wf.Inputs[r[1]]; !ok {
				v.warnf(path, "inputs.%s is not declared in inputs", r[1])
			}
		}
		if len(r) >= 2 && r[0] == "assets" {
			if _, ok := v.wf.Assets[r[1]]; !ok && !strings.ContainsAny(r[1], "*") {
				v.warnf(path, "assets.%s is not in assets", r[1])
			}
		}
	}
}

func (v *validator) checkRefs() {
	for _, r := range v.refs {
		if _, ok := v.allIDs[r.id]; !ok {
			v.errf(r.path, "steps.%s: no step has that id", r.id)
		}
	}
}

func (v *validator) steps(path string, list []*Step) {
	v.depth++
	defer func() { v.depth-- }()
	if v.depth > MaxDepth {
		v.errf(path, "steps are nested deeper than %d", MaxDepth)
		return
	}
	for i, s := range list {
		v.step(fmt.Sprintf("%s[%d]", path, i), s)
	}
}

func (v *validator) step(p string, s *Step) {
	if s == nil {
		v.errf(p, "a step cannot be null")
		return
	}
	if s.ID != "" {
		p = p + "(" + s.ID + ")"
		if !idRe.MatchString(s.ID) {
			v.errf(p+".id", "a step id is letters, digits and _ (refer to it as steps.%s)", s.ID)
		}
		if prev, dup := v.ids[s.ID]; dup {
			v.errf(p+".id", "id %q is already used at %s", s.ID, prev)
		}
		v.ids[s.ID] = p
		if v.allIDs == nil {
			v.allIDs = map[string]bool{}
		}
		v.allIDs[s.ID] = true
	}
	kinds := s.kinds()
	switch len(kinds) {
	case 0:
		v.errf(p, "a step needs a kind: action, upsert, model, sandbox, wait, set, assert, log, sleep, fail, steps or use")
	case 1:
	default:
		v.errf(p, "a step has one kind; this one has %s", strings.Join(kinds, ", "))
	}
	v.cond(p+".if", s.If)
	if s.With != nil && s.Action == "" && s.Use == "" {
		v.errf(p+".with", "with goes with action or use")
	}
	v.exprs(p+".with", s.With)
	if s.Action != "" {
		v.action(p+".action", s.Action)
	}
	if u := s.Upsert; u != nil {
		v.upsert(p+".upsert", u)
	}
	if m := s.Model; m != nil {
		if !modelTypes[m.Type] {
			v.errf(p+".model.type", "unknown model type %q", m.Type)
		}
		if m.Body == nil {
			v.errf(p+".model.body", "a model step needs a body (model, messages, …)")
		}
		v.exprs(p+".model.body", m.Body)
	}
	if b := s.Sandbox; b != nil {
		if b.Space == "" {
			v.errf(p+".sandbox.space", "which space's computer")
		}
		v.exprs(p+".sandbox", map[string]any{"space": b.Space, "root": b.Root, "env": b.Env, "proxy": b.Proxy, "exec": b.Exec, "workdir": b.Workdir})
		if b.Render {
			v.exprs(p+".sandbox.files", b.Files)
		}
		if strings.Contains(b.Root, "..") {
			v.errf(p+".sandbox.root", "the root stays inside /workspace")
		}
		for path := range b.Files {
			if strings.Contains(path, "..") || strings.HasPrefix(path, "/") {
				v.errf(p+".sandbox.files", "%q: a file path is relative and stays inside the root", path)
			}
		}
		if b.Assets != "" && b.Assets != "*" {
			found := false
			for name := range v.wf.Assets {
				found = found || strings.HasPrefix(name, b.Assets)
			}
			if !found {
				v.warnf(p+".sandbox.assets", "no asset starts with %q", b.Assets)
			}
		}
		if len(b.Files) == 0 && b.Assets == "" && b.Exec == nil && b.Proxy == nil && !b.Start && !b.Clean {
			v.warnf(p+".sandbox", "this sandbox step does nothing")
		}
	}
	if w := s.Wait; w != nil {
		if w.Action == "" {
			v.errf(p+".wait.action", "what to poll")
		} else {
			v.action(p+".wait.action", w.Action)
		}
		if w.Until == nil {
			v.errf(p+".wait.until", "when to stop waiting")
		}
		v.exprs(p+".wait.with", w.With)
		v.cond(p+".wait.until", w.Until)
	}
	for k := range s.Set {
		if !idRe.MatchString(k) {
			v.errf(p+".set."+k, "a var name is letters, digits and _")
		}
	}
	v.exprs(p+".set", s.Set)
	v.exprs(p+".export", s.Export)
	for k := range s.Export {
		if !idRe.MatchString(k) {
			v.errf(p+".export."+k, "a var name is letters, digits and _")
		}
	}
	switch a := s.Assert.(type) {
	case nil:
	case string, bool:
		v.cond(p+".assert", a)
	case map[string]any:
		v.cond(p+".assert.that", a["that"])
	case []any:
		for i, item := range a {
			if m, ok := item.(map[string]any); ok {
				v.cond(fmt.Sprintf("%s.assert[%d].that", p, i), m["that"])
			} else {
				v.cond(fmt.Sprintf("%s.assert[%d]", p, i), item)
			}
		}
	}
	v.exprs(p+".log", s.Log)
	v.exprs(p+".fail", s.Fail)
	v.exprs(p+".outputs", s.Outputs)
	v.exprs(p+".collect", s.Collect)
	if s.Use != "" {
		t, ok := v.wf.Templates[s.Use]
		if !ok {
			v.errf(p+".use", "no template named %q", s.Use)
		} else if with, ok := s.With.(map[string]any); ok || s.With == nil {
			for name, ps := range t.Params {
				if _, given := with[name]; ps.Required && !given && ps.Default == nil {
					v.errf(p+".with", "template %s needs %s", s.Use, name)
				}
			}
			for name := range with {
				if _, ok := t.Params[name]; !ok && len(t.Params) > 0 {
					v.warnf(p+".with."+name, "template %s has no param %s", s.Use, name)
				}
			}
		}
	}
	if s.ForEach != nil {
		v.exprs(p+".for_each", s.ForEach)
		for _, name := range []string{s.As, s.IndexAs} {
			if name != "" && !idRe.MatchString(name) {
				v.errf(p, "loop variable %q is letters, digits and _", name)
			}
		}
	} else if s.As != "" || s.IndexAs != "" || s.Collect != nil {
		v.errf(p, "as, index_as and collect go with for_each")
	}
	if s.Concurrency < 0 || s.Concurrency > MaxConcurrency {
		v.errf(p+".concurrency", "must be between 1 and %d", MaxConcurrency)
	}
	if s.Retry != nil {
		v.checkRetry(p+".retry", s.Retry)
	}
	if s.Plan != "" && s.Plan != "run" && s.Plan != "skip" {
		v.errf(p+".plan", `plan is "run" or "skip"`)
	}
	if s.Steps != nil {
		if len(s.Steps) == 0 {
			v.warnf(p+".steps", "an empty group")
		}
		v.steps(p+".steps", s.Steps)
	}
	if s.OnError != nil {
		v.steps(p+".on_error", s.OnError)
	}
	if s.Compensate != nil {
		v.step(p+".compensate", s.Compensate)
	}
}

func (v *validator) action(p, name string) {
	ns, act, ok := strings.Cut(name, ".")
	if !ok || ns == "" || act == "" {
		v.errf(p, "an action is namespace.action, e.g. spaces.space_create")
		return
	}
	if v.cat != nil {
		if ok, reason := v.cat.ActionExists(name); !ok {
			if reason == "" {
				reason = "no such action"
			}
			v.errf(p, "%s: %s", name, reason)
		}
	}
}

func (v *validator) optionalAction(p, name, use string) {
	if v.cat == nil {
		return
	}
	if ok, reason := v.cat.ActionExists(name); !ok {
		what := "updating it"
		if use == "delete" {
			what = "rolling it back"
		}
		v.warnf(p, "%s: %s — %s will fail", name, firstNonEmpty(reason, "no such action"), what)
	}
}

func (v *validator) upsert(p string, u *Upsert) {
	def := u.Define
	if u.Resource != "" {
		preset, ok := Presets[u.Resource]
		if !ok {
			v.errf(p+".resource", "unknown resource %q (built in: %s)", u.Resource, strings.Join(PresetNames(), ", "))
			return
		}
		def = preset.merge(u.Define)
	}
	if def == nil {
		v.errf(p, "an upsert names a resource or defines one")
		return
	}
	if def.Find == nil || def.Create == nil && u.Mode != "update" {
		v.errf(p+".define", "a resource needs find and create")
	}
	for name, c := range map[string]*Call{"find": def.Find, "create": def.Create, "update": def.Update, "delete": def.Delete} {
		if c == nil {
			continue
		}
		if name == "update" || name == "delete" {
			// Needed only to change what exists, or to roll back.
			v.optionalAction(p+".define."+name+".action", c.Action, name)
		} else {
			v.action(p+".define."+name+".action", c.Action)
		}
		if u.Define != nil {
			v.exprs(p+".define."+name+".with", c.With)
		}
		if name == "find" && c.Items == "" && c.Item == "" {
			v.errf(p+".define.find", "find says where the records are: items (a list) or item (one)")
		}
	}
	switch u.Mode {
	case "", "upsert", "ensure", "update", "create":
	default:
		v.errf(p+".mode", "mode is upsert, ensure, update or create")
	}
	if len(u.Match) == 0 && len(def.Match) == 0 && def.Find != nil && def.Find.Item == "" {
		v.errf(p+".match", "what identifies the resource (e.g. {\"name\": …})")
	}
	v.exprs(p+".match", u.Match)
	v.exprs(p+".with", u.With)
	v.exprs(p+".create_with", u.CreateWith)
	v.exprs(p+".update_with", u.UpdateWith)
}

// checkValue checks a value against an input spec.
func checkValue(in InputSpec, val any) error {
	if val == nil {
		return nil
	}
	switch in.Type {
	case "string":
		if _, ok := val.(string); !ok {
			return fmt.Errorf("must be a string")
		}
	case "number":
		if _, ok := toNumberStrict(val); !ok {
			return fmt.Errorf("must be a number")
		}
	case "integer":
		f, ok := toNumberStrict(val)
		if !ok || f != float64(int64(f)) {
			return fmt.Errorf("must be a whole number")
		}
	case "boolean":
		if _, ok := val.(bool); !ok {
			return fmt.Errorf("must be true or false")
		}
	case "object":
		if _, ok := val.(map[string]any); !ok {
			return fmt.Errorf("must be an object")
		}
	case "list", "array":
		if _, ok := val.([]any); !ok {
			return fmt.Errorf("must be a list")
		}
	}
	if len(in.Enum) > 0 && !contains(in.Enum, val) {
		return fmt.Errorf("must be one of %s", mustJSON(in.Enum))
	}
	if in.Pattern != "" {
		if s, ok := val.(string); ok {
			if re, err := regexp.Compile(in.Pattern); err == nil && !re.MatchString(s) {
				return fmt.Errorf("must match %s", in.Pattern)
			}
		}
	}
	if f, ok := toNumberStrict(val); ok {
		if in.Min != nil && f < *in.Min {
			return fmt.Errorf("must be at least %v", *in.Min)
		}
		if in.Max != nil && f > *in.Max {
			return fmt.Errorf("must be at most %v", *in.Max)
		}
	}
	if s, ok := val.(string); ok {
		n := float64(len([]rune(s)))
		if in.Min != nil && n < *in.Min {
			return fmt.Errorf("must be at least %v characters", *in.Min)
		}
		if in.Max != nil && n > *in.Max {
			return fmt.Errorf("must be at most %v characters", *in.Max)
		}
	}
	return nil
}

// ResolveInputs checks the inputs a run gives and fills in defaults.
func ResolveInputs(specs map[string]InputSpec, given map[string]any) (map[string]any, []Issue) {
	out := map[string]any{}
	var issues []Issue
	for name, spec := range specs {
		val, ok := given[name]
		if !ok || val == nil {
			if spec.Default != nil {
				val = spec.Default
			} else if spec.Required {
				issues = append(issues, Issue{Path: "inputs." + name, Message: "is required", Severity: "error"})
				continue
			}
		}
		if spec.Type == "integer" || spec.Type == "number" {
			if s, isStr := val.(string); isStr {
				if f, err := strconv.ParseFloat(s, 64); err == nil {
					val = f
				}
			}
		}
		if hasUnknown(val) {
			out[name] = val
			continue
		}
		if err := checkValue(spec, val); err != nil {
			issues = append(issues, Issue{Path: "inputs." + name, Message: err.Error(), Severity: "error"})
			continue
		}
		out[name] = val
	}
	for name, val := range given {
		if _, declared := specs[name]; !declared {
			issues = append(issues, Issue{Path: "inputs." + name, Message: "is not an input of this workflow", Severity: "warning"})
			out[name] = val
		}
	}
	sortIssues(issues)
	return out, issues
}

func sortIssues(issues []Issue) {
	sort.SliceStable(issues, func(i, j int) bool { return issues[i].Path < issues[j].Path })
}

// varOrder orders vars so each comes after the vars it reads.
func varOrder(vars map[string]any) ([]string, error) {
	deps := map[string][]string{}
	for name, val := range vars {
		set := map[string]bool{}
		expressionsIn(val, "", func(_, _ string, e *Expr, _ error) {
			if e == nil {
				return
			}
			for _, r := range e.Refs() {
				if len(r) >= 2 && r[0] == "vars" {
					if _, ok := vars[r[1]]; ok && r[1] != name {
						set[r[1]] = true
					} else if r[1] == name {
						set[name] = true
					}
				}
			}
		})
		for d := range set {
			deps[name] = append(deps[name], d)
		}
		sort.Strings(deps[name])
	}
	names := make([]string, 0, len(vars))
	for n := range vars {
		names = append(names, n)
	}
	sort.Strings(names)
	var order []string
	state := map[string]int{}
	var visit func(n string, chain []string) error
	visit = func(n string, chain []string) error {
		switch state[n] {
		case 1:
			return fmt.Errorf("vars refer to each other in a circle: %s", strings.Join(append(chain, n), " → "))
		case 2:
			return nil
		}
		state[n] = 1
		for _, d := range deps[n] {
			if err := visit(d, append(chain, n)); err != nil {
				return err
			}
		}
		state[n] = 2
		order = append(order, n)
		return nil
	}
	for _, n := range names {
		if err := visit(n, nil); err != nil {
			return nil, err
		}
	}
	return order, nil
}
