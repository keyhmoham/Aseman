package workflow

import (
	"fmt"
	"strings"
	"sync"
)

// Templates: any string in a workflow may hold `${{ expression }}`.
//
//   - A string that is exactly one expression keeps the expression's type:
//     "${{ inputs.count }}" is a number, "${{ steps.list.outputs }}" a list.
//   - Otherwise each expression is rendered as text in place.
//   - "$${{" writes a literal "${{".
//   - {"$raw": value} is taken as it is, never rendered (for source code that
//     itself contains "${{", like a CI file).
//   - Object keys are rendered too.

type segment struct {
	lit  string
	expr *Expr
}

var tplCache sync.Map // string → []segment

// parseTemplate splits a string into literal text and expressions.
func parseTemplate(s string) ([]segment, error) {
	if v, ok := tplCache.Load(s); ok {
		return v.([]segment), nil
	}
	var out []segment
	var lit strings.Builder
	i := 0
	for i < len(s) {
		if strings.HasPrefix(s[i:], "$${{") {
			lit.WriteString("${{")
			i += 4
			continue
		}
		if !strings.HasPrefix(s[i:], "${{") {
			lit.WriteByte(s[i])
			i++
			continue
		}
		end := closing(s, i+3)
		if end < 0 {
			return nil, fmt.Errorf("unclosed ${{ at %d", i)
		}
		src := strings.TrimSpace(s[i+3 : end])
		e, err := Parse(src)
		if err != nil {
			return nil, fmt.Errorf("in ${{ %s }}: %v", src, err)
		}
		if lit.Len() > 0 {
			out = append(out, segment{lit: lit.String()})
			lit.Reset()
		}
		out = append(out, segment{expr: e})
		i = end + 2
	}
	if lit.Len() > 0 || len(out) == 0 {
		out = append(out, segment{lit: lit.String()})
	}
	if len(s) < 4096 {
		tplCache.Store(s, out)
	}
	return out, nil
}

// closing finds the "}}" that ends an expression, skipping quoted text.
func closing(s string, from int) int {
	var quote byte
	for i := from; i < len(s); i++ {
		c := s[i]
		if quote != 0 {
			if c == '\\' {
				i++
			} else if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '\'', '"', '`':
			quote = c
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				return i
			}
		}
	}
	return -1
}

// HasTemplate reports whether a string holds an expression.
func HasTemplate(s string) bool { return strings.Contains(s, "${{") }

// RenderString renders one string.
func RenderString(s string, env Env) (any, error) {
	if !HasTemplate(s) {
		return s, nil
	}
	segs, err := parseTemplate(s)
	if err != nil {
		return nil, err
	}
	if len(segs) == 1 && segs[0].expr != nil {
		return segs[0].expr.Eval(env)
	}
	var b strings.Builder
	for _, seg := range segs {
		if seg.expr == nil {
			b.WriteString(seg.lit)
			continue
		}
		v, err := seg.expr.Eval(env)
		if err != nil {
			return nil, fmt.Errorf("${{ %s }}: %w", seg.expr.Source(), err)
		}
		b.WriteString(ToString(v))
	}
	return b.String(), nil
}

// Render renders every string inside a value.
func Render(v any, env Env) (any, error) {
	switch x := v.(type) {
	case string:
		return RenderString(x, env)
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			r, err := Render(e, env)
			if err != nil {
				return nil, fmt.Errorf("[%d]: %w", i, err)
			}
			out[i] = r
		}
		return out, nil
	case map[string]any:
		if raw, ok := x["$raw"]; ok && len(x) == 1 {
			return raw, nil
		}
		out := make(map[string]any, len(x))
		for k, e := range x {
			key := k
			if HasTemplate(k) {
				rk, err := RenderString(k, env)
				if err != nil {
					return nil, fmt.Errorf("key %q: %w", k, err)
				}
				key = ToString(rk)
			}
			r, err := Render(e, env)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", k, err)
			}
			out[key] = r
		}
		return out, nil
	}
	return v, nil
}

// EvalCondition evaluates an `if`/`until`: a boolean, or an expression with
// or without its ${{ }}.
func EvalCondition(cond any, env Env) (any, error) {
	switch c := cond.(type) {
	case nil:
		return true, nil
	case bool:
		return c, nil
	case string:
		c = strings.TrimSpace(c)
		if HasTemplate(c) {
			return RenderString(c, env)
		}
		e, err := Parse(c)
		if err != nil {
			return nil, err
		}
		return e.Eval(env)
	}
	return Truthy(cond), nil
}

// expressionsIn lists the expressions inside a value (for validation).
func expressionsIn(v any, path string, visit func(path string, src string, e *Expr, err error)) {
	switch x := v.(type) {
	case string:
		if !HasTemplate(x) {
			return
		}
		segs, err := parseTemplate(x)
		if err != nil {
			visit(path, x, nil, err)
			return
		}
		for _, s := range segs {
			if s.expr != nil {
				visit(path, s.expr.Source(), s.expr, nil)
			}
		}
	case []any:
		for i, e := range x {
			expressionsIn(e, fmt.Sprintf("%s[%d]", path, i), visit)
		}
	case map[string]any:
		if _, ok := x["$raw"]; ok && len(x) == 1 {
			return
		}
		for k, e := range x {
			expressionsIn(k, path, visit)
			expressionsIn(e, path+"."+k, visit)
		}
	}
}
