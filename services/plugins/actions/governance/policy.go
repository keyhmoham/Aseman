package governance

import (
	"fmt"
	"path"
	"strings"
	"sync"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"

	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
)

// Rules are CEL expressions over one request. The variables, all maps of
// strings unless noted:
//
//	tool       {name, kind, effect}
//	agent      {id, name}
//	actor      {id}
//	initiator  {kind, id}
//	space      {id}      room {id}
//	command    string    the project computer command, if any
//	file       {path, name, extension}
//	url        {full, host}
//	app        {slug, function}
//	mcp        {server, tool}
//	recipients list of strings
//	args       the arguments, as given
//
// Besides CEL's own (contains, startsWith, matches, in, ...), icontains(s, sub)
// compares without case.
//
// Deny rules are evaluated before ask and allow rules. The engine fails
// closed: no matching allow rule denies, a deny or ask rule that errors
// denies, an allow rule that errors does not permit.

// DefaultPolicy is the node's policy until an administrator saves one: reads
// and work inside Aseman run, and anything that sends to people outside it,
// pays, signs or deletes asks first. Cloud metadata is never reached.
func DefaultPolicy() gov.Policy {
	return gov.Policy{
		Scope: gov.NodeScope,
		Deny: []string{
			`url.host in ["169.254.169.254", "metadata.google.internal", "metadata.azure.com", "100.100.100.200", "fd00:ec2::254"]`,
			`command.matches("169\\.254\\.169\\.254|metadata\\.google\\.internal|100\\.100\\.100\\.200")`,
			`initiator.kind == "proactive" && tool.effect != "read"`,
		},
		Ask: []string{
			`tool.effect in ["send", "pay", "sign", "delete"]`,
			`tool.kind == "host" && tool.effect != "read"`,
		},
		Allow: []string{"true"},
	}
}

// ProjectDefault is a project's policy until its owner saves one: it adds
// nothing to the node's.
func ProjectDefault(scope string) gov.Policy {
	return gov.Policy{Scope: scope, Deny: []string{}, Ask: []string{}, Allow: []string{}}
}

var (
	envOnce sync.Once
	envErr  error
	celEnv  *cel.Env
)

func env() (*cel.Env, error) {
	envOnce.Do(func() {
		str := cel.MapType(cel.StringType, cel.StringType)
		celEnv, envErr = cel.NewEnv(
			cel.Variable("tool", str), cel.Variable("agent", str), cel.Variable("actor", str),
			cel.Variable("initiator", str), cel.Variable("space", str), cel.Variable("room", str),
			cel.Variable("command", cel.StringType), cel.Variable("file", str), cel.Variable("url", str),
			cel.Variable("app", str), cel.Variable("mcp", str),
			cel.Variable("recipients", cel.ListType(cel.StringType)), cel.Variable("args", cel.DynType),
			cel.Function("icontains", cel.Overload("icontains_string_string", []*cel.Type{cel.StringType, cel.StringType}, cel.BoolType,
				cel.BinaryBinding(func(a, b ref.Val) ref.Val {
					sa, _ := a.Value().(string)
					sb, _ := b.Value().(string)
					return types.Bool(strings.Contains(strings.ToLower(sa), strings.ToLower(sb)))
				}))),
		)
	})
	return celEnv, envErr
}

// rule is one compiled expression.
type rule struct {
	src  string
	prog cel.Program
}

// compiled is a policy ready to evaluate.
type compiled struct {
	version          int64
	deny, ask, allow []rule
}

// Compile checks every rule and returns the policy ready to evaluate. An
// expression that does not compile or is not boolean is an error naming it.
func Compile(p gov.Policy) (*compiled, error) {
	e, err := env()
	if err != nil {
		return nil, err
	}
	c := &compiled{version: p.Version}
	build := func(list string, srcs []string) ([]rule, error) {
		out := make([]rule, 0, len(srcs))
		for _, src := range srcs {
			src = strings.TrimSpace(src)
			if src == "" {
				continue
			}
			ast, iss := e.Compile(src)
			if iss != nil && iss.Err() != nil {
				return nil, fmt.Errorf("%s rule %q: %v", list, src, iss.Err())
			}
			if ast.OutputType() != cel.BoolType && ast.OutputType() != cel.DynType {
				return nil, fmt.Errorf("%s rule %q is not true or false", list, src)
			}
			prog, err := e.Program(ast)
			if err != nil {
				return nil, fmt.Errorf("%s rule %q: %v", list, src, err)
			}
			out = append(out, rule{src: src, prog: prog})
		}
		return out, nil
	}
	if c.deny, err = build("deny", p.Deny); err != nil {
		return nil, err
	}
	if c.ask, err = build("ask", p.Ask); err != nil {
		return nil, err
	}
	if c.allow, err = build("allow", p.Allow); err != nil {
		return nil, err
	}
	return c, nil
}

// verdict of one policy for one request.
type verdict struct {
	effect string // "deny", "ask", "allow" or "" (nothing matched)
	rule   string
}

// eval runs the request through the policy's lists in order.
func (c *compiled) eval(vars map[string]any) verdict {
	for _, r := range c.deny {
		if hit, ok := r.match(vars); hit || !ok {
			return verdict{effect: "deny", rule: r.src}
		}
	}
	for _, r := range c.ask {
		if hit, ok := r.match(vars); !ok {
			return verdict{effect: "deny", rule: r.src}
		} else if hit {
			return verdict{effect: "ask", rule: r.src}
		}
	}
	for _, r := range c.allow {
		if hit, ok := r.match(vars); ok && hit {
			return verdict{effect: "allow", rule: r.src}
		}
	}
	return verdict{}
}

// match is (matched, evaluated): an expression that errors did not evaluate.
func (r rule) match(vars map[string]any) (bool, bool) {
	out, _, err := r.prog.Eval(vars)
	if err != nil {
		return false, false
	}
	b, ok := out.Value().(bool)
	return b && ok, ok
}

// Vars is a request as the rules see it.
func Vars(req gate.Request) map[string]any {
	host, full := "", req.URL
	if full != "" {
		host = hostOf(full)
	}
	name, ext := "", ""
	if req.Path != "" {
		name = path.Base(req.Path)
		ext = strings.TrimPrefix(path.Ext(req.Path), ".")
	}
	var args any = map[string]any{}
	if len(req.Args) > 0 {
		if decoded := decodeJSON(req.Args); decoded != nil {
			args = decoded
		}
	}
	recipients := req.Recipients
	if recipients == nil {
		recipients = []string{}
	}
	return map[string]any{
		"tool":       map[string]string{"name": req.Tool, "kind": req.Kind, "effect": req.Effect},
		"agent":      map[string]string{"id": req.AgentID, "name": req.AgentName},
		"actor":      map[string]string{"id": req.ActorID},
		"initiator":  map[string]string{"kind": req.InitiatorKind, "id": req.InitiatorID},
		"space":      map[string]string{"id": req.SpaceID},
		"room":       map[string]string{"id": req.RoomID},
		"command":    req.Command,
		"file":       map[string]string{"path": req.Path, "name": name, "extension": ext},
		"url":        map[string]string{"full": full, "host": host},
		"app":        map[string]string{"slug": req.App, "function": req.Function},
		"mcp":        map[string]string{"server": req.MCPServer, "tool": req.MCPTool},
		"recipients": recipients,
		"args":       args,
	}
}

// decide combines the node's and the project's verdicts: a deny in either
// denies, an ask in either asks, and an action needs the node's allow and,
// when the project lists allow rules, the project's too.
func decide(node, project *compiled, vars map[string]any) verdict {
	nv := node.eval(vars)
	var pv verdict
	if project != nil {
		pv = project.eval(vars)
	}
	switch {
	case nv.effect == "deny":
		return nv
	case pv.effect == "deny":
		return pv
	case nv.effect == "ask":
		return nv
	case pv.effect == "ask":
		return pv
	case nv.effect != "allow":
		return verdict{effect: "deny", rule: "no node rule allows this"}
	case project != nil && len(project.allow) > 0 && pv.effect != "allow":
		return verdict{effect: "deny", rule: "no project rule allows this"}
	}
	return nv
}
