package spaces

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/a2ui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/webkit"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// An interactive web page an agent builds is reviewed before it opens on the
// desk, the way a generated frontend is before it is served
// (tools/review.go): the page is
//
//   - inspected: fetched from its preview and read the way the kit runs it
//     (webkit.InspectPage: the kit loaded, components that exist, valid
//     props, controls wired, inputs bound, the viewport, theme and layout),
//     its own files fetched too;
//   - tested: every call it declares or scripts is checked against the
//     space's tools, their microtools and schemas; what it loads when it
//     opens is really loaded, as the agent, and every value it shows is
//     looked up in what came back; buttons whose microtool only reads
//     (readOnlyHint) are run;
//   - looked at: the model reviews its source, with what its calls returned
//     and what the inspection found, for fitness to the tool and what was
//     asked, cleanness and the design standard (tools.ReviewPage).
//
// A page that does not work does not open: the agent gets the whole report
// to fix and opens it again (web_show), which reviews it again. What the
// design review finds comes back with the opened window, for the agent to
// fix before it tells anyone the page is ready.

// pageReview is what the review of a page found.
type pageReview struct {
	Page   string       `json:"page"`
	Passed bool         `json:"passed"`
	Tested []string     `json:"tested,omitempty"`
	Issues []a2ui.Issue `json:"issues,omitempty"`
	// broken counts the blocking issues the inspection and the tests found
	// (as opposed to the design review's judgement).
	broken int
}

func (r *pageReview) add(severity, area, where, problem, fix string) {
	r.Issues = append(r.Issues, a2ui.Issue{Severity: severity, Area: area, Where: where, Problem: problem, Fix: fix})
}

// report is the review as the agent is told it.
func (r *pageReview) report(opened bool) string {
	var b strings.Builder
	if opened {
		b.WriteString("The page was opened, but its review found problems: fix them and open it again with web_show (it is reviewed again) before telling anyone it is ready.")
	} else {
		b.WriteString("The page was fetched, inspected and tested before opening, and it does not work yet; it was not opened. Fix these, then open it again with web_show (it is reviewed again):")
	}
	for _, severity := range []string{a2ui.Blocking, a2ui.Advice} {
		for _, i := range r.Issues {
			if i.Severity == severity {
				b.WriteString("\n- " + i.Severity + " " + i.String())
			}
		}
	}
	if len(r.Tested) > 0 {
		b.WriteString("\nWhat the review ran:")
		for _, t := range r.Tested {
			b.WriteString("\n- " + t)
		}
	}
	return b.String()
}

// Bounds of a page review.
const (
	maxPageResources = 20
	maxPageSource    = 16000
	pageFetchTimeout = 15 * time.Second
)

// upstreamGet fetches [rest] (a path inside the preview, with its query)
// from a preview's persisted tunnel target, as the gateway would. Redirects
// are not followed (they cannot forward the tunnel's credentials).
func upstreamGet(ctx context.Context, record *proxy.Proxy, rest string, maxBody int64) (status int, contentType string, body []byte, complete bool, err error) {
	target, err := url.Parse(record.TargetURL)
	if err != nil || target.Host == "" || target.User != nil || (target.Scheme != "http" && target.Scheme != "https") {
		return 0, "", nil, false, errs.InvalidArgument("invalid persisted proxy target")
	}
	upstream := record.TargetURL
	if rest = strings.TrimLeft(rest, "/"); rest != "" {
		upstream = strings.TrimRight(record.TargetURL, "/") + "/" + rest
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstream, nil)
	if err != nil {
		return 0, "", nil, false, errs.InvalidArgument("invalid page path")
	}
	req.Header.Set("Authorization", "Bearer "+record.Token)
	req.Header.Set("Accept", "text/html,*/*")
	req.Header.Set("X-Forwarded-Prefix", strings.TrimRight(record.GatewayPath(), "/"))
	client := &http.Client{Timeout: pageFetchTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(req)
	if err != nil {
		// net/http errors can contain the private upstream URL. Do not expose it.
		return 0, "", nil, false, errs.New(errs.CodeUnavailable, "the preview did not answer; verify the service is listening on the exposed port")
	}
	defer response.Body.Close()
	body, err = io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if err != nil {
		return 0, "", nil, false, errs.New(errs.CodeUnavailable, "the preview's response could not be read")
	}
	complete = int64(len(body)) <= maxBody
	if !complete {
		body = body[:maxBody]
	}
	return response.StatusCode, response.Header.Get("Content-Type"), body, complete, nil
}

// pageProxy finds the preview a page path is served by, and the path inside it.
func (s *Service) pageProxy(ctx context.Context, spaceID identity.ID, page string) (*proxy.Proxy, string, error) {
	list, err := s.ProxyList(ctx, spaceID)
	if err != nil {
		return nil, "", err
	}
	var best *proxy.Proxy
	for i := range list {
		prefix := strings.TrimRight(list[i].GatewayPath(), "/")
		if (page == prefix || strings.HasPrefix(page, prefix+"/") || strings.HasPrefix(page, prefix+"?")) &&
			(best == nil || len(prefix) > len(strings.TrimRight(best.GatewayPath(), "/"))) {
			best = &list[i]
		}
	}
	if best == nil {
		return nil, "", errs.NotFound("no preview of this space serves " + page)
	}
	return best, strings.TrimPrefix(page, strings.TrimRight(best.GatewayPath(), "/")), nil
}

// pageTool is a tool a page calls, with its microtools.
type pageTool struct {
	tool     vmm.Tool
	commands map[string]map[string]any
}

// pageReviewer reviews pages: how it fetches a page's files, the space's
// tools and their microtools, how it runs one and how it has a page looked
// at.
type pageReviewer struct {
	fetch    func(rest string, maxBody int64) (status int, contentType string, body []byte, complete bool, err error)
	tools    []vmm.Tool
	commands func(vmm.Tool) map[string]map[string]any
	call     func(t *pageTool, microtool string, args map[string]any) (any, error)
	// look is the design review; nil skips it.
	look func(page string, inspected *webkit.Page, source []byte, data map[string]any, looked *pageTool,
		tools map[string]*pageTool, found []a2ui.Issue) ([]a2ui.Issue, error)
}

// reviewPage reviews the page at [page] (a preview gateway path) before it
// opens; [toolName] is the tool it is the frontend of, if any. It returns
// nil when the page is no preview of this space's (nothing to review).
func (s *Service) reviewPage(ctx context.Context, spaceID identity.ID, page, toolName string) *pageReview {
	record, rest, err := s.pageProxy(ctx, spaceID, page)
	if err != nil {
		return nil
	}
	tools, _ := s.SpaceTools(ctx, spaceID, identity.ID{})
	pr := &pageReviewer{
		fetch: func(rest string, maxBody int64) (int, string, []byte, bool, error) {
			return upstreamGet(ctx, record, rest, maxBody)
		},
		tools:    tools,
		commands: func(t vmm.Tool) map[string]map[string]any { return s.pageCommands(ctx, t, spaceID) },
		call: func(t *pageTool, microtool string, args map[string]any) (any, error) {
			return s.callPageTool(ctx, spaceID, t, microtool, args)
		},
		look: func(page string, inspected *webkit.Page, source []byte, data map[string]any, looked *pageTool,
			tools map[string]*pageTool, found []a2ui.Issue) ([]a2ui.Issue, error) {
			return s.lookAtPage(ctx, spaceID, page, inspected, source, data, looked, tools, found)
		},
	}
	return pr.review(page, rest, toolName)
}

// review reviews the page at [page], [rest] inside its preview.
func (pr *pageReviewer) review(page, rest, toolName string) *pageReview {
	r := &pageReview{Page: page}
	// What the inspection and the tests found is everything up to the
	// design review's issues.
	tested := -1
	defer func() {
		if tested < 0 {
			tested = len(r.Issues)
		}
		r.Passed = true
		for k, i := range r.Issues {
			if i.Severity == a2ui.Blocking {
				r.Passed = false
				if k < tested {
					r.broken++
				}
			}
		}
	}()
	status, contentType, body, complete, err := pr.fetch(rest, 2<<20)
	switch {
	case err != nil:
		r.add(a2ui.Blocking, "structure", page, err.Error(), "start the service (proxy_create with start) and check it answers")
		return r
	case status >= 300 && status < 400:
		r.Tested = append(r.Tested, fmt.Sprintf("the page answers a redirect (%d); not followed", status))
		return r
	case status >= 400:
		r.add(a2ui.Blocking, "structure", page, fmt.Sprintf("the page answers %d", status), "serve the page at this path")
		return r
	case contentType != "" && !strings.Contains(contentType, "html"):
		r.add(a2ui.Blocking, "structure", page, "the page is served as "+contentType+", not HTML", "serve an HTML page (Content-Type: text/html)")
		return r
	case !complete:
		r.add(a2ui.Advice, "structure", page, "the page is larger than 2 MiB; only its start was inspected", "split it into files")
	}
	r.Tested = append(r.Tested, fmt.Sprintf("fetched %s (%d bytes)", page, len(body)))
	inspected := webkit.InspectPage(body)
	r.Issues = append(r.Issues, inspected.Issues...)

	// Its own files.
	dir := rest
	if i := strings.IndexAny(dir, "?#"); i >= 0 {
		dir = dir[:i]
	}
	if !strings.HasSuffix(dir, "/") {
		dir = path.Dir("/" + strings.TrimLeft(dir, "/"))
	}
	seen := map[string]bool{}
	for _, ref := range inspected.Resources {
		file := ref
		if i := strings.IndexAny(file, "?#"); i >= 0 {
			file = file[:i]
		}
		file = path.Join("/", dir, file)
		if seen[file] || len(seen) >= maxPageResources {
			continue
		}
		seen[file] = true
		if status, _, _, _, err := pr.fetch(file, 1); err != nil || status >= 400 {
			why := "does not answer"
			if err == nil {
				why = fmt.Sprintf("answers %d", status)
			}
			r.add(a2ui.Blocking, "structure", ref, "the page loads "+ref+", which "+why, "serve the file next to the page, or fix the path")
		}
	}
	if len(seen) > 0 {
		r.Tested = append(r.Tested, fmt.Sprintf("fetched the page's %d own file(s)", len(seen)))
	}

	// Its calls: the tools and microtools they name, and their arguments.
	tools := pr.tools
	resolved := map[string]*pageTool{}
	resolve := func(name string) *pageTool {
		if t, ok := resolved[name]; ok {
			return t
		}
		var out *pageTool
		for i := range tools {
			if tools[i].BotID != "" && (tools[i].BotID == name || strings.EqualFold(tools[i].Name, name)) {
				out = &pageTool{tool: tools[i], commands: pr.commands(tools[i])}
				break
			}
		}
		resolved[name] = out
		return out
	}
	toolNames := make([]string, 0, len(tools))
	for _, t := range tools {
		if t.BotID != "" {
			toolNames = append(toolNames, t.Name)
		}
	}
	sort.Strings(toolNames)
	data := map[string]any{}
	var sources []a2ui.Source
	ran := map[string]bool{}
	var looked *pageTool
	for _, c := range inspected.Calls {
		name := c.Tool + "/" + c.Microtool
		t := resolve(c.Tool)
		if t == nil {
			r.add(a2ui.Blocking, "interaction", c.Element, "calls "+name+", but "+c.Tool+" is no tool of this space (its tools: "+strings.Join(toolNames, ", ")+")",
				"call one of the space's tools by its name")
			continue
		}
		if looked == nil {
			looked = t
		}
		cmd, ok := t.commands[c.Microtool]
		if !ok && len(t.commands) > 0 {
			names := make([]string, 0, len(t.commands))
			for n := range t.commands {
				names = append(names, n)
			}
			sort.Strings(names)
			r.add(a2ui.Blocking, "interaction", c.Element, "calls "+name+", but "+t.tool.Name+" has no microtool "+c.Microtool+" (it has: "+strings.Join(names, ", ")+")",
				"call one of its microtools")
			continue
		}
		schema, _ := cmd["schema"].(map[string]any)
		if !c.Script {
			given := map[string]any{}
			for k, v := range c.Args {
				given[k] = v
			}
			for _, f := range c.Fields {
				given[f] = "(entered)"
			}
			r.Issues = append(r.Issues, a2ui.CheckArgs(c.Element, name, schema, given,
				`in args='{…}', as a binding {"path": "/form/…"}, or as a named field of the form`)...)
		}

		// Run it: what loads when the page opens, and what only reads.
		annotations, _ := cmd["annotations"].(map[string]any)
		readOnly, _ := annotations["readOnlyHint"].(bool)
		args, missing := pageArgs(c.Args, data, schema)
		run := c.Load || readOnly
		note := ""
		switch {
		case !run:
			note = "checked " + name + " (" + c.Element + "), not run: it may change data"
		case len(c.Fields) > 0 || missing != "":
			note = "checked " + name + " (" + c.Element + "), not run: it needs " + firstOf(missing, "the form's fields") + " entered"
			run = false
		}
		src := a2ui.Source{Path: c.Into, From: name, Optional: !c.Load}
		if run {
			key := name + compactJSON(args)
			if ran[key] {
				continue
			}
			ran[key] = true
			value, err := pr.call(t, c.Microtool, args)
			if err != nil {
				r.add(a2ui.Blocking, "data", c.Element, name+" failed when the review ran it with "+compactJSON(args)+": "+err.Error(),
					"call it with arguments its schema accepts")
				src.Err = err.Error()
				note = "ran " + name + ": failed"
			} else {
				note = "ran " + name + " with " + compactJSON(args) + " (" + shapeOf(value) + ")"
				if c.Into != "" {
					setDataPointer(data, c.Into, value)
				}
			}
			src.Live = true
		} else if c.Script && c.Into == "" {
			note = "found " + name + " in a script; its arguments are code, so it was checked by name"
		}
		r.Tested = append(r.Tested, note)
		if c.Into != "" {
			sources = append(sources, src)
		}
	}

	// Every value shown is filled, and is there in what came back.
	unfilled := a2ui.Blocking
	if inspected.ScriptsWrite {
		unfilled = a2ui.Advice // its scripts may write it
	}
	r.Issues = append(r.Issues, a2ui.CheckReads(inspected.Reads, inspected.Writes, inspected.Aliases, data, sources, unfilled)...)

	// The page as a whole, looked at.
	if looked == nil && toolName != "" {
		looked = resolve(toolName)
	}
	tested = len(r.Issues)
	if pr.look == nil {
		return r
	}
	if issues, err := pr.look(page, inspected, body, data, looked, resolved, r.Issues); err != nil {
		r.Tested = append(r.Tested, "design review unavailable: "+err.Error())
	} else if issues != nil {
		r.Issues = append(r.Issues, issues...)
		r.Tested = append(r.Tested, "design review of the page")
	}
	return r
}

// pageCommands are a tool's microtools by name: asked of the tools namespace
// (with their schemas and annotations), or as the space lists them.
func (s *Service) pageCommands(ctx context.Context, t vmm.Tool, spaceID identity.ID) map[string]map[string]any {
	out := map[string]map[string]any{}
	var commands []map[string]any
	actor := vmm.ExecutionFrom(ctx).ActorID
	if err := bridge.Invoke(ctx, s.K, "tools", "CommandsFor", []any{ctx, t.BotID, actor, spaceID.String()}, &commands); err != nil || len(commands) == 0 {
		for _, c := range t.Commands {
			commands = append(commands, map[string]any{"name": c.Name, "description": c.Description, "schema": c.Schema})
		}
	}
	for _, c := range commands {
		if name, _ := c["name"].(string); name != "" {
			out[name] = c
		}
	}
	return out
}

// pageArgs resolves a call's arguments as the kit does when the page opens:
// bindings read the data model ({"path"}), and what is still empty is left
// out. [missing] names a required argument that would be empty.
func pageArgs(args map[string]any, data map[string]any, schema map[string]any) (map[string]any, string) {
	out := map[string]any{}
	for k, v := range args {
		if b, ok := v.(map[string]any); ok {
			if p, ok := b["path"].(string); ok && len(b) <= 2 {
				if value, ok, _ := a2ui.Lookup(data, a2ui.JoinPath("", p)); ok && value != nil {
					out[k] = value
				}
				continue
			}
		}
		out[k] = v
	}
	_, required := a2ui.SchemaArgs(schema)
	for _, r := range required {
		if v, ok := out[r]; !ok || v == nil || v == "" {
			return out, "\"" + r + "\""
		}
	}
	return out, ""
}

// callPageTool runs a microtool as the agent reviewing the page.
func (s *Service) callPageTool(ctx context.Context, spaceID identity.ID, t *pageTool, microtool string, args map[string]any) (any, error) {
	botID, err := identity.Parse(t.tool.BotID)
	if err != nil {
		return nil, errs.InvalidArgument("the tool has no backend")
	}
	if args == nil {
		args = map[string]any{}
	}
	body, _ := json.Marshal(map[string]any{"function": microtool, "payload": args})
	reply, err := s.AskBot(ctx, spaceID, botID, string(body), nil, nil)
	if err != nil {
		return nil, err
	}
	return vmm.ToolResultValue(reply)
}

// lookAtPage has the model review the page (tools.ReviewPage), billed to
// whoever the agent's turn is for. It returns nil, nil when there is no one
// to bill or no tool to bill it as.
func (s *Service) lookAtPage(ctx context.Context, spaceID identity.ID, page string, inspected *webkit.Page, source []byte,
	data map[string]any, looked *pageTool, tools map[string]*pageTool, found []a2ui.Issue) ([]a2ui.Issue, error) {
	payer := s.turnPayer(ctx)
	if payer == "" || looked == nil || s.K == nil {
		return nil, nil
	}
	var b strings.Builder
	b.WriteString("Page: " + page + "\nTitle: " + inspected.Title + "\nIt is the frontend of " + looked.tool.Name + ": " + strings.TrimSpace(looked.tool.Description) + "\n")
	b.WriteString("\nTools it calls:\n")
	names := make([]string, 0, len(tools))
	for name, t := range tools {
		if t != nil {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		t := tools[name]
		b.WriteString("- " + t.tool.Name + ": " + strings.TrimSpace(t.tool.Description) + "\n")
		mts := make([]string, 0, len(t.commands))
		for mt := range t.commands {
			mts = append(mts, mt)
		}
		sort.Strings(mts)
		for _, mt := range mts {
			desc, _ := t.commands[mt]["description"].(string)
			b.WriteString("  - " + mt + ": " + strings.TrimSpace(desc) + "\n")
		}
	}
	html := string(source)
	if len(html) > maxPageSource {
		html = html[:maxPageSource] + "\n…(cut)"
	}
	b.WriteString("\nHTML source:\n" + html + "\n")
	if len(data) > 0 {
		raw, _ := json.Marshal(data)
		text := string(raw)
		if len(text) > 6000 {
			text = text[:6000] + "…"
		}
		b.WriteString("\nWhat its calls returned when the page was opened for the review (the data model): " + text + "\n")
	}
	if len(found) > 0 {
		b.WriteString("\nAutomatic findings (already reported):\n")
		for _, i := range found {
			b.WriteString("- " + i.Severity + " " + i.String() + "\n")
		}
	}
	room := vmm.RoomFrom(ctx)
	var raw string
	if err := bridge.Invoke(ctx, s.K, "tools", "ReviewPage", []any{ctx, payer, spaceID.String(), room, looked.tool.BotID, b.String()}, &raw); err != nil {
		return nil, err
	}
	var issues []a2ui.Issue
	if err := json.Unmarshal([]byte(raw), &issues); err != nil {
		return nil, err
	}
	return issues, nil
}

func compactJSON(v any) string {
	raw, _ := json.Marshal(v)
	if len(raw) > 120 {
		return string(raw[:120]) + "…"
	}
	return string(raw)
}

// shapeOf sums up a result for the review's account of it.
func shapeOf(v any) string {
	switch x := v.(type) {
	case []any:
		return fmt.Sprintf("a list of %d", len(x))
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if len(keys) > 8 {
			keys = append(keys[:8], "…")
		}
		return "an object with " + strings.Join(keys, ", ")
	case nil:
		return "nothing"
	}
	return compactJSON(v)
}

func firstOf(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
