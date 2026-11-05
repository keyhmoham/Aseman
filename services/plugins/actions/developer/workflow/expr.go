package workflow

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
)

// The expression language a workflow writes inside `${{ … }}`.
//
//	inputs.name                      paths into the context
//	steps.space.outputs.id           a step's outputs
//	vars.list[0]["key"]              indexing
//	a == b, a != b, <, <=, >, >=     comparison
//	a && b, a || b, !a               logic (short-circuit; || answers a value)
//	a ?? b                           the first that is not null
//	a + b, -, *, /, %                arithmetic (+ also joins strings and lists)
//	x in list, "k" in map            membership
//	cond ? a : b                     choice
//	fn(a, b), map(list, x => x.id)   functions and lambdas (see funcs.go)
//
// Reading a field of null is null, so optional data needs no guard; the
// validator still checks that every steps.<id> a workflow names exists.

// Unknown is a value a plan cannot know yet (an output of a step that has not
// run). Every operation on it is unknown too, so a plan can still render the
// rest of a request and show where the value will go.
type Unknown struct{ Ref string }

func (u *Unknown) String() string { return "«" + u.Ref + "»" }

// Expr is a parsed expression.
type Expr struct {
	src  string
	root node
}

// Source is the text the expression was parsed from.
func (e *Expr) Source() string { return e.src }

// Eval evaluates the expression against an environment.
func (e *Expr) Eval(env Env) (any, error) { return e.root.eval(env) }

// Refs lists the context paths the expression reads (e.g. "steps.space"), as
// far as they are written literally.
func (e *Expr) Refs() [][]string {
	var out [][]string
	walk(e.root, func(n node) {
		if p, ok := n.(*pathNode); ok {
			out = append(out, p.literal())
		}
	})
	return out
}

// Env resolves names and functions while an expression runs.
type Env interface {
	Lookup(name string) (any, bool)
	Func(name string) (Func, bool)
}

// Func is a function callable from an expression. Lambdas arrive as *Lambda.
type Func func(env Env, args []any) (any, error)

// Lambda is an `x => expr` argument.
type Lambda struct {
	params []string
	body   node
	env    Env
}

// Call runs the lambda with arguments bound to its parameters.
func (l *Lambda) Call(args ...any) (any, error) {
	scope := &boundEnv{parent: l.env, vars: map[string]any{}}
	for i, p := range l.params {
		if i < len(args) {
			scope.vars[p] = args[i]
		} else {
			scope.vars[p] = nil
		}
	}
	return l.body.eval(scope)
}

type boundEnv struct {
	parent Env
	vars   map[string]any
}

func (b *boundEnv) Lookup(name string) (any, bool) {
	if v, ok := b.vars[name]; ok {
		return v, true
	}
	return b.parent.Lookup(name)
}
func (b *boundEnv) Func(name string) (Func, bool) { return b.parent.Func(name) }

// ---- lexer ----

type tokKind int

const (
	tEOF tokKind = iota
	tNum
	tStr
	tIdent
	tOp
)

type token struct {
	kind tokKind
	text string
	num  float64
	pos  int
}

var ops = []string{"=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "(", ")", "[", "]", ".", ",", "!", "<", ">", "+", "-", "*", "/", "%", "?", ":"}

func lex(src string) ([]token, error) {
	var out []token
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case c >= '0' && c <= '9':
			j := i
			for j < len(src) && (src[j] >= '0' && src[j] <= '9' || src[j] == '.' || src[j] == '_' || src[j] == 'e' || src[j] == 'E' ||
				((src[j] == '+' || src[j] == '-') && j > i && (src[j-1] == 'e' || src[j-1] == 'E'))) {
				// "1.foo" is not a number followed by a field: numbers stop
				// before a dot that is not followed by a digit.
				if src[j] == '.' && (j+1 >= len(src) || src[j+1] < '0' || src[j+1] > '9') {
					break
				}
				j++
			}
			n, err := strconv.ParseFloat(strings.ReplaceAll(src[i:j], "_", ""), 64)
			if err != nil {
				return nil, fmt.Errorf("bad number %q at %d", src[i:j], i)
			}
			out = append(out, token{kind: tNum, num: n, text: src[i:j], pos: i})
			i = j
		case c == '\'' || c == '"' || c == '`':
			s, n, err := lexString(src[i:])
			if err != nil {
				return nil, fmt.Errorf("%v at %d", err, i)
			}
			out = append(out, token{kind: tStr, text: s, pos: i})
			i += n
		case c == '_' || c == '$' || unicode.IsLetter(rune(c)):
			j := i
			for j < len(src) && (src[j] == '$' || isIdentChar(src[j])) {
				j++
			}
			out = append(out, token{kind: tIdent, text: src[i:j], pos: i})
			i = j
		default:
			matched := false
			for _, op := range ops {
				if strings.HasPrefix(src[i:], op) {
					out = append(out, token{kind: tOp, text: op, pos: i})
					i += len(op)
					matched = true
					break
				}
			}
			if !matched {
				return nil, fmt.Errorf("unexpected %q at %d", string(c), i)
			}
		}
	}
	return append(out, token{kind: tEOF, pos: len(src)}), nil
}

func isIdentChar(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

func lexString(src string) (string, int, error) {
	q := src[0]
	var b strings.Builder
	for i := 1; i < len(src); i++ {
		c := src[i]
		if c == q {
			return b.String(), i + 1, nil
		}
		if c == '\\' && i+1 < len(src) {
			i++
			switch src[i] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case '0':
				b.WriteByte(0)
			default:
				b.WriteByte(src[i])
			}
			continue
		}
		b.WriteByte(c)
	}
	return "", 0, fmt.Errorf("unterminated string")
}

// ---- parser ----

type parser struct {
	toks []token
	i    int
	src  string
}

// Parse parses an expression.
func Parse(src string) (*Expr, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks, src: src}
	if p.peek().kind == tEOF {
		return nil, fmt.Errorf("empty expression")
	}
	n, err := p.expr(0)
	if err != nil {
		return nil, err
	}
	if p.peek().kind != tEOF {
		return nil, fmt.Errorf("unexpected %q at %d", p.peek().text, p.peek().pos)
	}
	return &Expr{src: src, root: n}, nil
}

func (p *parser) peek() token { return p.toks[p.i] }
func (p *parser) next() token { t := p.toks[p.i]; p.i++; return t }
func (p *parser) isOp(s string) bool {
	t := p.peek()
	return t.kind == tOp && t.text == s
}
func (p *parser) expect(s string) error {
	if !p.isOp(s) {
		t := p.peek()
		if t.kind == tEOF {
			return fmt.Errorf("expected %q at the end", s)
		}
		return fmt.Errorf("expected %q at %d, found %q", s, t.pos, t.text)
	}
	p.i++
	return nil
}

// binding powers
func infix(t token) (int, bool) {
	if t.kind == tIdent && t.text == "in" {
		return 45, true
	}
	if t.kind != tOp {
		return 0, false
	}
	switch t.text {
	case "?":
		return 10, true
	case "??":
		return 15, true
	case "||":
		return 20, true
	case "&&":
		return 30, true
	case "==", "!=":
		return 40, true
	case "<", "<=", ">", ">=":
		return 45, true
	case "+", "-":
		return 50, true
	case "*", "/", "%":
		return 60, true
	case ".", "?.", "[", "(":
		return 80, true
	}
	return 0, false
}

func (p *parser) expr(minBP int) (node, error) {
	left, err := p.prefix()
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		bp, ok := infix(t)
		if !ok || bp <= minBP {
			return left, nil
		}
		p.next()
		switch {
		case t.text == "?" && t.kind == tOp:
			a, err := p.expr(0)
			if err != nil {
				return nil, err
			}
			if err := p.expect(":"); err != nil {
				return nil, err
			}
			b, err := p.expr(bp - 1)
			if err != nil {
				return nil, err
			}
			left = &condNode{cond: left, a: a, b: b}
		case t.text == "." || t.text == "?.":
			name := p.next()
			if name.kind != tIdent && name.kind != tNum {
				return nil, fmt.Errorf("expected a field name after '.' at %d", name.pos)
			}
			left = &indexNode{target: left, key: &litNode{v: name.text}, dotted: true}
		case t.text == "[":
			key, err := p.expr(0)
			if err != nil {
				return nil, err
			}
			if err := p.expect("]"); err != nil {
				return nil, err
			}
			left = &indexNode{target: left, key: key}
		case t.text == "(":
			name, ok := left.(*identNode)
			if !ok {
				return nil, fmt.Errorf("only named functions can be called (at %d)", t.pos)
			}
			args, err := p.args()
			if err != nil {
				return nil, err
			}
			left = &callNode{name: name.name, args: args}
		default:
			right, err := p.expr(bp)
			if err != nil {
				return nil, err
			}
			left = &binNode{op: t.text, a: left, b: right}
		}
	}
}

func (p *parser) args() ([]node, error) {
	var args []node
	if p.isOp(")") {
		p.next()
		return args, nil
	}
	for {
		a, err := p.arg()
		if err != nil {
			return nil, err
		}
		args = append(args, a)
		if p.isOp(",") {
			p.next()
			continue
		}
		if err := p.expect(")"); err != nil {
			return nil, err
		}
		return args, nil
	}
}

// arg is an expression or a lambda: `x => …` or `(a, b) => …`.
func (p *parser) arg() (node, error) {
	if t := p.peek(); t.kind == tIdent && p.toks[p.i+1].kind == tOp && p.toks[p.i+1].text == "=>" {
		p.i += 2
		body, err := p.expr(0)
		if err != nil {
			return nil, err
		}
		return &lambdaNode{params: []string{t.text}, body: body}, nil
	}
	if p.isOp("(") {
		// (a, b) => …
		j := p.i + 1
		var params []string
		for j < len(p.toks) && p.toks[j].kind == tIdent {
			params = append(params, p.toks[j].text)
			j++
			if p.toks[j].kind == tOp && p.toks[j].text == "," {
				j++
				continue
			}
			break
		}
		if j+1 < len(p.toks) && p.toks[j].kind == tOp && p.toks[j].text == ")" && p.toks[j+1].kind == tOp && p.toks[j+1].text == "=>" {
			p.i = j + 2
			body, err := p.expr(0)
			if err != nil {
				return nil, err
			}
			return &lambdaNode{params: params, body: body}, nil
		}
	}
	return p.expr(0)
}

func (p *parser) prefix() (node, error) {
	t := p.next()
	switch t.kind {
	case tNum:
		return &litNode{v: t.num}, nil
	case tStr:
		return &litNode{v: t.text}, nil
	case tIdent:
		switch t.text {
		case "true":
			return &litNode{v: true}, nil
		case "false":
			return &litNode{v: false}, nil
		case "null", "nil":
			return &litNode{v: nil}, nil
		case "not":
			n, err := p.expr(70)
			return &unNode{op: "!", a: n}, err
		}
		return &identNode{name: t.text}, nil
	case tOp:
		switch t.text {
		case "(":
			n, err := p.expr(0)
			if err != nil {
				return nil, err
			}
			return n, p.expect(")")
		case "!", "-", "+":
			n, err := p.expr(70)
			return &unNode{op: t.text, a: n}, err
		case "[":
			var items []node
			for !p.isOp("]") {
				n, err := p.expr(0)
				if err != nil {
					return nil, err
				}
				items = append(items, n)
				if p.isOp(",") {
					p.next()
					continue
				}
				break
			}
			return &listNode{items: items}, p.expect("]")
		}
	case tEOF:
		return nil, fmt.Errorf("unexpected end of expression")
	}
	return nil, fmt.Errorf("unexpected %q at %d", t.text, t.pos)
}

// ---- nodes ----

type node interface{ eval(Env) (any, error) }

func walk(n node, fn func(node)) {
	fn(n)
	switch x := n.(type) {
	case *indexNode:
		if p := x.path(); p != nil {
			fn(p)
		}
		walk(x.target, fn)
		walk(x.key, fn)
	case *binNode:
		walk(x.a, fn)
		walk(x.b, fn)
	case *unNode:
		walk(x.a, fn)
	case *condNode:
		walk(x.cond, fn)
		walk(x.a, fn)
		walk(x.b, fn)
	case *callNode:
		for _, a := range x.args {
			walk(a, fn)
		}
	case *listNode:
		for _, a := range x.items {
			walk(a, fn)
		}
	case *lambdaNode:
		walk(x.body, fn)
	case *identNode:
		fn(&pathNode{parts: []string{x.name}})
	}
}

type litNode struct{ v any }

func (n *litNode) eval(Env) (any, error) { return n.v, nil }

type identNode struct{ name string }

func (n *identNode) eval(env Env) (any, error) {
	v, ok := env.Lookup(n.name)
	if !ok {
		return nil, fmt.Errorf("unknown name %q", n.name)
	}
	return v, nil
}

// pathNode is only produced for Refs.
type pathNode struct{ parts []string }

func (n *pathNode) eval(Env) (any, error) { return nil, nil }
func (n *pathNode) literal() []string     { return n.parts }

type indexNode struct {
	target, key node
	dotted      bool
}

// path is the literal path an index chain spells (a.b["c"]), if it does.
func (n *indexNode) path() *pathNode {
	var parts []string
	var cur node = n
	for {
		switch x := cur.(type) {
		case *indexNode:
			lit, ok := x.key.(*litNode)
			if !ok {
				return nil
			}
			s, ok := lit.v.(string)
			if !ok {
				if f, isNum := lit.v.(float64); isNum {
					s = strconv.Itoa(int(f))
				} else {
					return nil
				}
			}
			parts = append([]string{s}, parts...)
			cur = x.target
		case *identNode:
			return &pathNode{parts: append([]string{x.name}, parts...)}
		default:
			return nil
		}
	}
}

func (n *indexNode) eval(env Env) (any, error) {
	t, err := n.target.eval(env)
	if err != nil {
		return nil, err
	}
	k, err := n.key.eval(env)
	if err != nil {
		return nil, err
	}
	return index(t, k, n.refText())
}

func (n *indexNode) refText() string {
	if p := n.path(); p != nil {
		return strings.Join(p.parts, ".")
	}
	return "value"
}

func index(t, k any, ref string) (any, error) {
	if u, ok := t.(*Unknown); ok {
		return &Unknown{Ref: u.Ref + "." + ToString(k)}, nil
	}
	if u, ok := k.(*Unknown); ok {
		return u, nil
	}
	switch c := t.(type) {
	case nil:
		return nil, nil
	case map[string]any:
		return c[ToString(k)], nil
	case []any:
		f, ok := toNumber(k)
		if !ok {
			if s, isStr := k.(string); isStr && s == "length" {
				return float64(len(c)), nil
			}
			return nil, nil
		}
		i := int(f)
		if i < 0 {
			i += len(c)
		}
		if i < 0 || i >= len(c) {
			return nil, nil
		}
		return c[i], nil
	case string:
		if s, ok := k.(string); ok && s == "length" {
			return float64(len([]rune(c))), nil
		}
		f, ok := toNumber(k)
		if !ok {
			return nil, nil
		}
		r := []rune(c)
		i := int(f)
		if i < 0 {
			i += len(r)
		}
		if i < 0 || i >= len(r) {
			return nil, nil
		}
		return string(r[i]), nil
	}
	return nil, nil
}

type listNode struct{ items []node }

func (n *listNode) eval(env Env) (any, error) {
	out := make([]any, 0, len(n.items))
	for _, it := range n.items {
		v, err := it.eval(env)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

type lambdaNode struct {
	params []string
	body   node
}

func (n *lambdaNode) eval(env Env) (any, error) {
	return &Lambda{params: n.params, body: n.body, env: env}, nil
}

type callNode struct {
	name string
	args []node
}

func (n *callNode) eval(env Env) (any, error) {
	fn, ok := env.Func(n.name)
	if !ok {
		return nil, fmt.Errorf("unknown function %s()", n.name)
	}
	args := make([]any, 0, len(n.args))
	for _, a := range n.args {
		v, err := a.eval(env)
		if err != nil {
			return nil, err
		}
		args = append(args, v)
	}
	// Functions that look at their arguments' shape get unknowns too; the
	// rest are unknown as soon as an argument is.
	if !lenientFuncs[n.name] {
		for _, a := range args {
			if u, ok := a.(*Unknown); ok {
				return &Unknown{Ref: n.name + "(" + u.Ref + ")"}, nil
			}
		}
	}
	out, err := fn(env, args)
	if err != nil {
		return nil, fmt.Errorf("%s(): %w", n.name, err)
	}
	return out, nil
}

// lenientFuncs see unknown arguments as they are.
var lenientFuncs = map[string]bool{"default": true, "coalesce": true, "is_unknown": true, "json": true, "string": true, "format": true, "concat": true, "merge": true, "list": true, "object": true}

type unNode struct {
	op string
	a  node
}

func (n *unNode) eval(env Env) (any, error) {
	v, err := n.a.eval(env)
	if err != nil {
		return nil, err
	}
	if u, ok := v.(*Unknown); ok {
		return u, nil
	}
	switch n.op {
	case "!":
		return !Truthy(v), nil
	case "-":
		f, ok := toNumber(v)
		if !ok {
			return nil, fmt.Errorf("cannot negate %s", typeName(v))
		}
		return -f, nil
	default:
		f, ok := toNumber(v)
		if !ok {
			return nil, fmt.Errorf("not a number: %s", typeName(v))
		}
		return f, nil
	}
}

type condNode struct{ cond, a, b node }

func (n *condNode) eval(env Env) (any, error) {
	c, err := n.cond.eval(env)
	if err != nil {
		return nil, err
	}
	if u, ok := c.(*Unknown); ok {
		return u, nil
	}
	if Truthy(c) {
		return n.a.eval(env)
	}
	return n.b.eval(env)
}

type binNode struct {
	op   string
	a, b node
}

func (n *binNode) eval(env Env) (any, error) {
	a, err := n.a.eval(env)
	if err != nil {
		return nil, err
	}
	switch n.op {
	case "&&":
		if _, ok := a.(*Unknown); !ok && !Truthy(a) {
			return a, nil
		}
		b, err := n.b.eval(env)
		if err != nil {
			return nil, err
		}
		if u, ok := a.(*Unknown); ok {
			return u, nil
		}
		return b, nil
	case "||":
		if _, ok := a.(*Unknown); !ok && Truthy(a) {
			return a, nil
		}
		b, err := n.b.eval(env)
		if err != nil {
			return nil, err
		}
		if u, ok := a.(*Unknown); ok {
			return u, nil
		}
		return b, nil
	case "??":
		if a != nil {
			return a, nil
		}
		return n.b.eval(env)
	}
	b, err := n.b.eval(env)
	if err != nil {
		return nil, err
	}
	if u, ok := a.(*Unknown); ok {
		return u, nil
	}
	if u, ok := b.(*Unknown); ok {
		return u, nil
	}
	return binary(n.op, a, b)
}

func binary(op string, a, b any) (any, error) {
	switch op {
	case "==":
		return Equal(a, b), nil
	case "!=":
		return !Equal(a, b), nil
	case "in":
		return contains(b, a), nil
	case "+":
		if as, ok := a.(string); ok {
			return as + ToString(b), nil
		}
		if bs, ok := b.(string); ok {
			return ToString(a) + bs, nil
		}
		if al, ok := a.([]any); ok {
			if bl, ok := b.([]any); ok {
				return append(append([]any{}, al...), bl...), nil
			}
			return append(append([]any{}, al...), b), nil
		}
		if am, ok := a.(map[string]any); ok {
			if bm, ok := b.(map[string]any); ok {
				return mergeMaps(am, bm), nil
			}
		}
	case "<", "<=", ">", ">=":
		c, ok := compare(a, b)
		if !ok {
			return nil, fmt.Errorf("cannot compare %s with %s", typeName(a), typeName(b))
		}
		switch op {
		case "<":
			return c < 0, nil
		case "<=":
			return c <= 0, nil
		case ">":
			return c > 0, nil
		default:
			return c >= 0, nil
		}
	}
	x, okA := toNumber(a)
	y, okB := toNumber(b)
	if !okA || !okB {
		return nil, fmt.Errorf("%s needs numbers, got %s and %s", op, typeName(a), typeName(b))
	}
	switch op {
	case "+":
		return x + y, nil
	case "-":
		return x - y, nil
	case "*":
		return x * y, nil
	case "/":
		if y == 0 {
			return nil, fmt.Errorf("division by zero")
		}
		return x / y, nil
	case "%":
		if y == 0 {
			return nil, fmt.Errorf("division by zero")
		}
		return math.Mod(x, y), nil
	}
	return nil, fmt.Errorf("unknown operator %s", op)
}

// ---- values ----

// Truthy is a value's truth: false, null, 0, "", "false", [] and {} are false.
func Truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case float64:
		return x != 0
	case int:
		return x != 0
	case int64:
		return x != 0
	case string:
		return x != "" && x != "false" && x != "0"
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	case *Unknown:
		return true
	}
	return true
}

func toNumber(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f, err == nil
	}
	return 0, false
}

// ToString renders a value as text: numbers without a needless ".0", lists
// and objects as JSON.
func ToString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		if x == math.Trunc(x) && math.Abs(x) < 1e15 {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'f', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case *Unknown:
		return x.String()
	}
	return mustJSON(v)
}

// Equal compares loosely across number types and deeply across containers.
func Equal(a, b any) bool {
	if x, ok := toNumberStrict(a); ok {
		if y, ok := toNumberStrict(b); ok {
			return x == y
		}
	}
	switch x := a.(type) {
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !Equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok || !Equal(v, w) {
				return false
			}
		}
		return true
	}
	return a == b
}

func toNumberStrict(v any) (float64, bool) {
	switch v.(type) {
	case float64, int, int64:
		return toNumber(v)
	}
	return 0, false
}

func compare(a, b any) (int, bool) {
	if x, ok := toNumberStrict(a); ok {
		if y, ok := toNumber(b); ok {
			return cmpFloat(x, y), true
		}
	}
	if as, ok := a.(string); ok {
		if bs, ok := b.(string); ok {
			return strings.Compare(as, bs), true
		}
		if y, ok := toNumberStrict(b); ok {
			if x, ok := toNumber(as); ok {
				return cmpFloat(x, y), true
			}
		}
	}
	return 0, false
}

func cmpFloat(x, y float64) int {
	switch {
	case x < y:
		return -1
	case x > y:
		return 1
	}
	return 0
}

func contains(container, item any) bool {
	switch c := container.(type) {
	case []any:
		for _, x := range c {
			if Equal(x, item) {
				return true
			}
		}
	case map[string]any:
		_, ok := c[ToString(item)]
		return ok
	case string:
		return strings.Contains(c, ToString(item))
	}
	return false
}

func typeName(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case float64, int, int64:
		return "number"
	case string:
		return "string"
	case []any:
		return "list"
	case map[string]any:
		return "object"
	case *Lambda:
		return "lambda"
	case *Unknown:
		return "unknown"
	}
	return fmt.Sprintf("%T", v)
}

func mergeMaps(a, b map[string]any) map[string]any {
	out := make(map[string]any, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}
