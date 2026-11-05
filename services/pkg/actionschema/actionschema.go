// Package actionschema reads the input schema of every platform action from
// the source: the struct an action's handler decodes its request body into
// (helper.Decode / json.Unmarshal of req.Body). Agents see these schemas in
// the API catalog (aseman_api_search), so they call actions with the right
// fields instead of guessing. cmd/gen-action-schemas writes them out.
//
// Actions are found where they are declared: helper.Action{Namespace, Name,
// Handler} literals, and types whose Meta() returns api.ActionMeta{Namespace,
// Name} (their Handle method is the handler). Fields carry their JSON names
// and JSON types; nothing is marked required (the handlers decide that).
package actionschema

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	pathpkg "path"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

// Encode is the stable, reviewable form of the schemas (sorted keys, indented).
func Encode(schemas map[string]map[string]any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", " ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(schemas); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Generate reads every package of the module and returns, for the actions
// declared under root, "namespace.action" → JSON schema.
func Generate(module, root string) (map[string]map[string]any, error) {
	modPath, err := modulePath(module)
	if err != nil {
		return nil, err
	}
	dirs := map[string]bool{}
	err = filepath.WalkDir(module, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && path != module && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules" || d.Name() == "testdata") {
			return filepath.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
			dirs[filepath.Dir(path)] = true
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(dirs))
	for d := range dirs {
		names = append(names, d)
	}
	sort.Strings(names)
	w := &world{pkgs: map[string]*pkg{}}
	for _, dir := range names {
		rel, _ := filepath.Rel(module, dir)
		p, err := readPackage(dir)
		if err != nil {
			return nil, err
		}
		p.w = w
		w.pkgs[modPath+"/"+filepath.ToSlash(rel)] = p
		p.dir = rel
	}
	rootRel, _ := filepath.Rel(module, filepath.Join(module, root))
	if filepath.IsAbs(root) {
		rootRel, _ = filepath.Rel(module, root)
	}
	out := map[string]map[string]any{}
	for _, dir := range names {
		rel, _ := filepath.Rel(module, dir)
		if rel != rootRel && !strings.HasPrefix(rel, rootRel+string(filepath.Separator)) {
			continue
		}
		w.pkgs[modPath+"/"+filepath.ToSlash(rel)].actions(out)
	}
	return out, nil
}

func modulePath(dir string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "go.mod"))
	if err != nil {
		return "", err
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if f := strings.Fields(l); len(f) == 2 && f[0] == "module" {
			return f[1], nil
		}
	}
	return "", fmt.Errorf("%s/go.mod names no module", dir)
}

type world struct{ pkgs map[string]*pkg }

type pkg struct {
	w       *world
	dir     string
	files   []*ast.File
	imports map[string]string // alias → import path
	consts  map[string]string
	types   map[string]ast.Expr
	funcs   map[string]*ast.FuncDecl // "Recv.Name" and "Name"
	methods map[string][]*ast.FuncDecl
}

func readPackage(dir string) (*pkg, error) {
	fset := token.NewFileSet()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	p := &pkg{imports: map[string]string{}, consts: map[string]string{}, types: map[string]ast.Expr{}, funcs: map[string]*ast.FuncDecl{}, methods: map[string][]*ast.FuncDecl{}}
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, filepath.Join(dir, n), nil, parser.SkipObjectResolution)
		if err != nil {
			return nil, err
		}
		p.files = append(p.files, f)
	}
	for _, f := range p.files {
		for _, im := range f.Imports {
			path, _ := strconv.Unquote(im.Path.Value)
			alias := pathpkg.Base(path)
			if im.Name != nil {
				alias = im.Name.Name
			}
			p.imports[alias] = path
		}
		for _, d := range f.Decls {
			switch d := d.(type) {
			case *ast.GenDecl:
				for _, sp := range d.Specs {
					switch sp := sp.(type) {
					case *ast.TypeSpec:
						p.types[sp.Name.Name] = sp.Type
					case *ast.ValueSpec:
						for i, n := range sp.Names {
							if i < len(sp.Values) {
								if s, ok := stringLit(sp.Values[i]); ok {
									p.consts[n.Name] = s
								}
							}
						}
					}
				}
			case *ast.FuncDecl:
				p.funcs[funcKey(d)] = d
				p.methods[d.Name.Name] = append(p.methods[d.Name.Name], d)
			}
		}
	}
	return p, nil
}

// actions records the schema of every action the package declares.
func (p *pkg) actions(out map[string]map[string]any) {
	for _, f := range p.files {
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.CompositeLit:
				if isSel(n.Type, "helper", "Action") {
					p.helperAction(n, out)
				}
			case *ast.FuncDecl:
				if n.Name.Name == "Meta" && n.Recv != nil {
					p.metaAction(n, out)
				}
			}
			return true
		})
	}
}

func funcKey(d *ast.FuncDecl) string {
	if d.Recv == nil || len(d.Recv.List) == 0 {
		return d.Name.Name
	}
	return recvName(d.Recv.List[0].Type) + "." + d.Name.Name
}

func recvName(e ast.Expr) string {
	switch e := e.(type) {
	case *ast.StarExpr:
		return recvName(e.X)
	case *ast.Ident:
		return e.Name
	case *ast.IndexExpr:
		return recvName(e.X)
	}
	return ""
}

func isSel(e ast.Expr, pkgName, name string) bool {
	s, ok := e.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	x, ok := s.X.(*ast.Ident)
	return ok && x.Name == pkgName && s.Sel.Name == name
}

func stringLit(e ast.Expr) (string, bool) {
	b, ok := e.(*ast.BasicLit)
	if !ok || b.Kind != token.STRING {
		return "", false
	}
	s, err := strconv.Unquote(b.Value)
	return s, err == nil
}

func (p *pkg) str(e ast.Expr) string {
	if s, ok := stringLit(e); ok {
		return s
	}
	if id, ok := e.(*ast.Ident); ok {
		return p.consts[id.Name]
	}
	return ""
}

func fieldsOf(lit *ast.CompositeLit) map[string]ast.Expr {
	m := map[string]ast.Expr{}
	for _, el := range lit.Elts {
		if kv, ok := el.(*ast.KeyValueExpr); ok {
			if k, ok := kv.Key.(*ast.Ident); ok {
				m[k.Name] = kv.Value
			}
		}
	}
	return m
}

func (p *pkg) helperAction(lit *ast.CompositeLit, out map[string]map[string]any) {
	f := fieldsOf(lit)
	ns, name := p.str(f["Namespace"]), p.str(f["Name"])
	if ns == "" || name == "" {
		return
	}
	var body *ast.BlockStmt
	switch h := f["Handler"].(type) {
	case *ast.FuncLit:
		body = h.Body
	case *ast.SelectorExpr:
		if ds := p.methods[h.Sel.Name]; len(ds) == 1 {
			body = ds[0].Body
		}
	case *ast.Ident:
		if d := p.funcs[h.Name]; d != nil {
			body = d.Body
		}
	case *ast.CallExpr:
		// A handler made by a function (legacy note; gadget_remove is direct).
		switch fn := h.Fun.(type) {
		case *ast.SelectorExpr:
			if ds := p.methods[fn.Sel.Name]; len(ds) == 1 {
				body = ds[0].Body
			}
		case *ast.Ident:
			if d := p.funcs[fn.Name]; d != nil {
				body = d.Body
			}
		}
	}
	p.record(ns+"."+name, body, out)
}

func (p *pkg) metaAction(d *ast.FuncDecl, out map[string]map[string]any) {
	var meta *ast.CompositeLit
	ast.Inspect(d.Body, func(n ast.Node) bool {
		if c, ok := n.(*ast.CompositeLit); ok && isSel(c.Type, "api", "ActionMeta") {
			meta = c
			return false
		}
		return true
	})
	if meta == nil {
		return
	}
	f := fieldsOf(meta)
	ns, name := p.str(f["Namespace"]), p.str(f["Name"])
	if ns == "" || name == "" {
		return
	}
	var body *ast.BlockStmt
	if h := p.funcs[recvName(d.Recv.List[0].Type)+".Handle"]; h != nil {
		body = h.Body
	}
	p.record(ns+"."+name, body, out)
}

// record stores the schema of what body decodes its request into, following
// one call into a same-package function or method that receives the request.
func (p *pkg) record(key string, body *ast.BlockStmt, out map[string]map[string]any) {
	if body == nil {
		return
	}
	if s := p.decoded(body, 2); s != nil {
		out[key] = s
	}
}

func (p *pkg) decoded(body *ast.BlockStmt, depth int) map[string]any {
	vars := localTypes(body)
	var found map[string]any
	var calls []*ast.CallExpr
	ast.Inspect(body, func(n ast.Node) bool {
		if found != nil {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		target := decodeTarget(call)
		if target == "" {
			calls = append(calls, call)
			return true
		}
		if t, ok := vars[target]; ok {
			if s := p.schema(t, 0); s != nil && s["type"] == "object" {
				found = s
			}
		}
		return true
	})
	if found != nil || depth == 0 {
		return found
	}
	// A handler that hands the request on: s.fooAction(ctx, req) or foo(ctx, req).
	for _, c := range calls {
		if !passesReq(c) {
			continue
		}
		var d *ast.FuncDecl
		switch fn := c.Fun.(type) {
		case *ast.SelectorExpr:
			if ds := p.methods[fn.Sel.Name]; len(ds) == 1 {
				d = ds[0]
			}
		case *ast.Ident:
			d = p.funcs[fn.Name]
		}
		if d != nil && d.Body != nil && d.Body != body {
			if s := p.decoded(d.Body, depth-1); s != nil {
				return s
			}
		}
	}
	return nil
}

func passesReq(c *ast.CallExpr) bool {
	for _, a := range c.Args {
		if id, ok := a.(*ast.Ident); ok && id.Name == "req" {
			return true
		}
	}
	return false
}

// decodeTarget is X of helper.Decode(req, &X) or json.Unmarshal(req.Body, &X).
func decodeTarget(call *ast.CallExpr) string {
	if len(call.Args) != 2 {
		return ""
	}
	switch {
	case isSel(call.Fun, "helper", "Decode"):
		if id, ok := call.Args[0].(*ast.Ident); !ok || id.Name != "req" {
			return ""
		}
	case isSel(call.Fun, "json", "Unmarshal"):
		s, ok := call.Args[0].(*ast.SelectorExpr)
		if !ok || s.Sel.Name != "Body" {
			return ""
		}
		if id, ok := s.X.(*ast.Ident); !ok || id.Name != "req" {
			return ""
		}
	default:
		return ""
	}
	u, ok := call.Args[1].(*ast.UnaryExpr)
	if !ok || u.Op != token.AND {
		return ""
	}
	id, ok := u.X.(*ast.Ident)
	if !ok {
		return ""
	}
	return id.Name
}

// localTypes are the types of the variables a body declares: var x T, x := T{}.
func localTypes(body *ast.BlockStmt) map[string]ast.Expr {
	m := map[string]ast.Expr{}
	ast.Inspect(body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.ValueSpec:
			if n.Type != nil {
				for _, id := range n.Names {
					m[id.Name] = n.Type
				}
			}
		case *ast.AssignStmt:
			if n.Tok == token.DEFINE {
				for i, l := range n.Lhs {
					if id, ok := l.(*ast.Ident); ok && i < len(n.Rhs) {
						if c, ok := n.Rhs[i].(*ast.CompositeLit); ok && c.Type != nil {
							m[id.Name] = c.Type
						}
					}
				}
			}
		}
		return true
	})
	return m
}

// schema is the JSON schema of a Go type as encoding/json reads it.
func (p *pkg) schema(t ast.Expr, depth int) map[string]any {
	if depth > 8 {
		return map[string]any{}
	}
	switch t := t.(type) {
	case *ast.StarExpr:
		return p.schema(t.X, depth)
	case *ast.ParenExpr:
		return p.schema(t.X, depth)
	case *ast.StructType:
		props := map[string]any{}
		for _, f := range t.Fields.List {
			name, skip := jsonName(f)
			if skip {
				continue
			}
			if len(f.Names) == 0 {
				// An embedded struct's fields are promoted.
				if s := p.schema(f.Type, depth+1); s != nil {
					if inner, ok := s["properties"].(map[string]any); ok && name == "" {
						for k, v := range inner {
							props[k] = v
						}
						continue
					}
					if name != "" {
						props[name] = s
					}
				}
				continue
			}
			for _, n := range f.Names {
				if !n.IsExported() {
					continue
				}
				key := name
				if key == "" {
					key = n.Name
				}
				props[key] = p.schema(f.Type, depth+1)
			}
		}
		return map[string]any{"type": "object", "properties": props}
	case *ast.ArrayType:
		if id, ok := t.Elt.(*ast.Ident); ok && id.Name == "byte" {
			return map[string]any{"type": "string"}
		}
		return map[string]any{"type": "array", "items": p.schema(t.Elt, depth+1)}
	case *ast.MapType:
		return map[string]any{"type": "object"}
	case *ast.InterfaceType:
		return map[string]any{}
	case *ast.Ident:
		switch t.Name {
		case "string":
			return map[string]any{"type": "string"}
		case "bool":
			return map[string]any{"type": "boolean"}
		case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64":
			return map[string]any{"type": "integer"}
		case "float32", "float64":
			return map[string]any{"type": "number"}
		case "any":
			return map[string]any{}
		}
		if def, ok := p.types[t.Name]; ok {
			return p.schema(def, depth+1)
		}
		return map[string]any{}
	case *ast.SelectorExpr:
		switch t.Sel.Name {
		case "ID", "Time", "Duration":
			if t.Sel.Name == "Duration" {
				return map[string]any{"type": "integer"}
			}
			return map[string]any{"type": "string"}
		case "RawMessage":
			return map[string]any{}
		}
		if x, ok := t.X.(*ast.Ident); ok {
			if other := p.w.pkgs[p.imports[x.Name]]; other != nil {
				if def, ok := other.types[t.Sel.Name]; ok {
					return other.schema(def, depth+1)
				}
			}
		}
		return map[string]any{}
	}
	return map[string]any{}
}

// jsonName is a field's JSON name ("" when untagged) and whether encoding/json skips it.
func jsonName(f *ast.Field) (string, bool) {
	if f.Tag == nil {
		return "", false
	}
	tag, err := strconv.Unquote(f.Tag.Value)
	if err != nil {
		return "", false
	}
	v, ok := reflect.StructTag(tag).Lookup("json")
	if !ok {
		return "", false
	}
	name := strings.Split(v, ",")[0]
	if name == "-" {
		return "", true
	}
	return name, false
}
