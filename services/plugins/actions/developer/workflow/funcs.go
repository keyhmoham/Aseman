package workflow

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// FuncDoc describes a built-in function for the reference.
type FuncDoc struct {
	Name    string `json:"name"`
	Usage   string `json:"usage"`
	Summary string `json:"summary"`
}

type builtin struct {
	doc FuncDoc
	fn  Func
}

var builtins = map[string]builtin{}

func def(name, usage, summary string, fn Func) {
	builtins[name] = builtin{doc: FuncDoc{Name: name, Usage: usage, Summary: summary}, fn: fn}
}

// Functions lists the built-in functions, by name.
func Functions() []FuncDoc {
	out := make([]FuncDoc, 0, len(builtins))
	for _, b := range builtins {
		out = append(out, b.doc)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func argN(args []any, n int, name string) error {
	if len(args) < n {
		return fmt.Errorf("needs %d argument(s)", n)
	}
	return nil
}

func str(args []any, i int) string {
	if i < len(args) {
		return ToString(args[i])
	}
	return ""
}

func num(args []any, i int, fallback float64) float64 {
	if i < len(args) {
		if f, ok := toNumber(args[i]); ok {
			return f
		}
	}
	return fallback
}

func list(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case nil:
		return nil
	case map[string]any:
		keys := sortedKeys(x)
		out := make([]any, 0, len(keys))
		for _, k := range keys {
			out = append(out, x[k])
		}
		return out
	}
	return []any{v}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// selector reads an item through a lambda or a field path ("a.b").
func selector(v any) (func(any) (any, error), error) {
	switch s := v.(type) {
	case *Lambda:
		return func(x any) (any, error) { return s.Call(x) }, nil
	case string:
		parts := strings.Split(s, ".")
		return func(x any) (any, error) {
			cur := x
			for _, p := range parts {
				var err error
				if cur, err = index(cur, p, s); err != nil {
					return nil, err
				}
			}
			return cur, nil
		}, nil
	}
	return nil, fmt.Errorf("expected a lambda (x => …) or a field name")
}

// predicate is a lambda, or a field name and a value it must equal.
func predicate(args []any, from int) (func(any) (bool, error), error) {
	if from >= len(args) {
		return nil, fmt.Errorf("needs a condition")
	}
	sel, err := selector(args[from])
	if err != nil {
		return nil, err
	}
	if _, isLambda := args[from].(*Lambda); isLambda || from+1 >= len(args) {
		return func(x any) (bool, error) {
			v, err := sel(x)
			return Truthy(v), err
		}, nil
	}
	want := args[from+1]
	return func(x any) (bool, error) {
		v, err := sel(x)
		if err != nil {
			return false, err
		}
		if ws, ok := want.(string); ok {
			if vs, ok := v.(string); ok {
				return strings.EqualFold(vs, ws), nil
			}
		}
		return Equal(v, want), nil
	}, nil
}

var slugRe = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = slugRe.ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}

func mustJSON(v any) string {
	b, err := json.Marshal(sanitize(v))
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

// sanitize turns values JSON cannot hold (lambdas, unknowns) into text.
func sanitize(v any) any {
	switch x := v.(type) {
	case *Unknown:
		return x.String()
	case *Lambda:
		return "<lambda>"
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = sanitize(e)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = sanitize(e)
		}
		return out
	}
	return v
}

func init() {
	// --- text ---
	def("lower", "lower(s)", "Lower-case text.", func(_ Env, a []any) (any, error) { return strings.ToLower(str(a, 0)), nil })
	def("upper", "upper(s)", "Upper-case text.", func(_ Env, a []any) (any, error) { return strings.ToUpper(str(a, 0)), nil })
	def("trim", "trim(s, chars?)", "Trim spaces (or the given characters) from both ends.", func(_ Env, a []any) (any, error) {
		if len(a) > 1 {
			return strings.Trim(str(a, 0), str(a, 1)), nil
		}
		return strings.TrimSpace(str(a, 0)), nil
	})
	def("title", "title(s)", "Capitalise each word.", func(_ Env, a []any) (any, error) {
		words := strings.Fields(str(a, 0))
		for i, w := range words {
			r := []rune(w)
			r[0] = unicode.ToUpper(r[0])
			words[i] = string(r)
		}
		return strings.Join(words, " "), nil
	})
	def("slug", "slug(s)", "A URL-safe slug: lower-case words joined by '-'.", func(_ Env, a []any) (any, error) { return slugify(str(a, 0)), nil })
	def("starts_with", "starts_with(s, prefix)", "Whether text starts with a prefix.", func(_ Env, a []any) (any, error) { return strings.HasPrefix(str(a, 0), str(a, 1)), nil })
	def("ends_with", "ends_with(s, suffix)", "Whether text ends with a suffix.", func(_ Env, a []any) (any, error) { return strings.HasSuffix(str(a, 0), str(a, 1)), nil })
	def("replace", "replace(s, old, new)", "Replace every occurrence.", func(_ Env, a []any) (any, error) {
		return strings.ReplaceAll(str(a, 0), str(a, 1), str(a, 2)), nil
	})
	def("regex_match", "regex_match(s, pattern)", "Whether text matches a regular expression.", func(_ Env, a []any) (any, error) {
		re, err := regexp.Compile(str(a, 1))
		if err != nil {
			return nil, err
		}
		return re.MatchString(str(a, 0)), nil
	})
	def("regex_replace", "regex_replace(s, pattern, repl)", "Replace regular-expression matches ($1 refers to groups).", func(_ Env, a []any) (any, error) {
		re, err := regexp.Compile(str(a, 1))
		if err != nil {
			return nil, err
		}
		return re.ReplaceAllString(str(a, 0), str(a, 2)), nil
	})
	def("regex_find", "regex_find(s, pattern)", "The first match's groups (or the match) as a list; null if none.", func(_ Env, a []any) (any, error) {
		re, err := regexp.Compile(str(a, 1))
		if err != nil {
			return nil, err
		}
		m := re.FindStringSubmatch(str(a, 0))
		if m == nil {
			return nil, nil
		}
		out := make([]any, len(m))
		for i, s := range m {
			out[i] = s
		}
		return out, nil
	})
	def("split", "split(s, sep)", "Split text into a list.", func(_ Env, a []any) (any, error) {
		s := str(a, 0)
		if s == "" {
			return []any{}, nil
		}
		parts := strings.Split(s, str(a, 1))
		out := make([]any, len(parts))
		for i, p := range parts {
			out[i] = p
		}
		return out, nil
	})
	def("join", "join(list, sep)", "Join a list into text.", func(_ Env, a []any) (any, error) {
		items := list(first(a))
		parts := make([]string, len(items))
		for i, it := range items {
			parts[i] = ToString(it)
		}
		return strings.Join(parts, str(a, 1)), nil
	})
	def("substr", "substr(s, start, length?)", "Part of a text, by characters.", func(_ Env, a []any) (any, error) {
		r := []rune(str(a, 0))
		start := clampInt(int(num(a, 1, 0)), len(r))
		end := len(r)
		if len(a) > 2 {
			end = clampInt(start+int(num(a, 2, 0)), len(r))
		}
		if end < start {
			end = start
		}
		return string(r[start:end]), nil
	})
	def("truncate", "truncate(s, n)", "Text cut to n characters, with … when cut.", func(_ Env, a []any) (any, error) {
		r := []rune(str(a, 0))
		n := int(num(a, 1, 80))
		if len(r) <= n {
			return string(r), nil
		}
		return string(r[:max(n-1, 0)]) + "…", nil
	})
	def("format", "format(template, args...)", "Fill {0}, {1}… (or {name} from one object) in a template.", func(_ Env, a []any) (any, error) {
		t := str(a, 0)
		if len(a) == 2 {
			if m, ok := a[1].(map[string]any); ok {
				for k, v := range m {
					t = strings.ReplaceAll(t, "{"+k+"}", ToString(v))
				}
				return t, nil
			}
		}
		for i := 1; i < len(a); i++ {
			t = strings.ReplaceAll(t, "{"+strconv.Itoa(i-1)+"}", ToString(a[i]))
		}
		return t, nil
	})
	def("indent", "indent(s, n)", "Indent every line by n spaces.", func(_ Env, a []any) (any, error) {
		pad := strings.Repeat(" ", int(num(a, 1, 2)))
		lines := strings.Split(str(a, 0), "\n")
		for i, l := range lines {
			if l != "" {
				lines[i] = pad + l
			}
		}
		return strings.Join(lines, "\n"), nil
	})
	def("url_encode", "url_encode(s)", "Escape text for a URL query.", func(_ Env, a []any) (any, error) { return url.QueryEscape(str(a, 0)), nil })

	// --- encoding ---
	def("json", "json(v, indent?)", "Encode a value as JSON text.", func(_ Env, a []any) (any, error) {
		if len(a) > 1 && Truthy(a[1]) {
			b, err := json.MarshalIndent(sanitize(first(a)), "", "  ")
			return string(b), err
		}
		return mustJSON(first(a)), nil
	})
	def("from_json", "from_json(s)", "Decode JSON text.", func(_ Env, a []any) (any, error) {
		var v any
		if err := json.Unmarshal([]byte(str(a, 0)), &v); err != nil {
			return nil, err
		}
		return v, nil
	})
	def("base64", "base64(s)", "Base64-encode text.", func(_ Env, a []any) (any, error) {
		return base64.StdEncoding.EncodeToString([]byte(str(a, 0))), nil
	})
	def("base64_decode", "base64_decode(s)", "Decode base64 into text.", func(_ Env, a []any) (any, error) {
		b, err := base64.StdEncoding.DecodeString(str(a, 0))
		return string(b), err
	})
	def("sha256", "sha256(s)", "The SHA-256 of text, in hex.", func(_ Env, a []any) (any, error) {
		sum := sha256.Sum256([]byte(str(a, 0)))
		return hex.EncodeToString(sum[:]), nil
	})

	// --- conversion & checks ---
	def("string", "string(v)", "A value as text (objects as JSON).", func(_ Env, a []any) (any, error) { return ToString(first(a)), nil })
	def("int", "int(v)", "A value as a whole number.", func(_ Env, a []any) (any, error) {
		f, ok := toNumber(first(a))
		if !ok {
			return nil, fmt.Errorf("not a number: %q", ToString(first(a)))
		}
		return math.Trunc(f), nil
	})
	def("number", "number(v)", "A value as a number.", func(_ Env, a []any) (any, error) {
		f, ok := toNumber(first(a))
		if !ok {
			return nil, fmt.Errorf("not a number: %q", ToString(first(a)))
		}
		return f, nil
	})
	def("bool", "bool(v)", "A value's truth.", func(_ Env, a []any) (any, error) { return Truthy(first(a)), nil })
	def("type_of", "type_of(v)", "null, boolean, number, string, list or object.", func(_ Env, a []any) (any, error) { return typeName(first(a)), nil })
	def("empty", "empty(v)", "Whether a value is null, \"\", [] or {}.", func(_ Env, a []any) (any, error) { return isEmpty(first(a)), nil })
	def("not_empty", "not_empty(v)", "The opposite of empty(v).", func(_ Env, a []any) (any, error) { return !isEmpty(first(a)), nil })
	def("is_unknown", "is_unknown(v)", "In a plan: whether a value is only known once the run gets there.", func(_ Env, a []any) (any, error) {
		_, ok := first(a).(*Unknown)
		return ok, nil
	})
	def("default", "default(v, fallback)", "The value, or the fallback when it is null or empty.", func(_ Env, a []any) (any, error) {
		if v := first(a); !isEmpty(v) {
			return v, nil
		}
		if len(a) > 1 {
			return a[1], nil
		}
		return nil, nil
	})
	def("coalesce", "coalesce(a, b, …)", "The first argument that is not null or empty.", func(_ Env, a []any) (any, error) {
		for _, v := range a {
			if !isEmpty(v) {
				return v, nil
			}
		}
		return nil, nil
	})
	def("len", "len(v)", "Length of a text, list or object.", lengthFn)
	def("length", "length(v)", "Same as len(v).", lengthFn)
	def("contains", "contains(container, item)", "Whether a list holds an item, an object a key, or a text a part.", func(_ Env, a []any) (any, error) {
		if err := argN(a, 2, "contains"); err != nil {
			return nil, err
		}
		return contains(a[0], a[1]), nil
	})

	// --- objects ---
	def("keys", "keys(obj)", "An object's keys, sorted.", func(_ Env, a []any) (any, error) {
		m, _ := first(a).(map[string]any)
		out := []any{}
		for _, k := range sortedKeys(m) {
			out = append(out, k)
		}
		return out, nil
	})
	def("values", "values(obj)", "An object's values, by sorted key.", func(_ Env, a []any) (any, error) { return emptyList(list(first(a))), nil })
	def("entries", "entries(obj)", "An object as a list of {key, value}.", func(_ Env, a []any) (any, error) {
		m, _ := first(a).(map[string]any)
		out := []any{}
		for _, k := range sortedKeys(m) {
			out = append(out, map[string]any{"key": k, "value": m[k]})
		}
		return out, nil
	})
	def("from_entries", "from_entries(list)", "An object from a list of {key, value} (or [key, value]).", func(_ Env, a []any) (any, error) {
		out := map[string]any{}
		for _, e := range list(first(a)) {
			switch x := e.(type) {
			case map[string]any:
				out[ToString(x["key"])] = x["value"]
			case []any:
				if len(x) == 2 {
					out[ToString(x[0])] = x[1]
				}
			}
		}
		return out, nil
	})
	def("merge", "merge(a, b, …)", "Objects merged left to right (deeply).", func(_ Env, a []any) (any, error) {
		out := map[string]any{}
		for _, v := range a {
			if m, ok := v.(map[string]any); ok {
				out = deepMerge(out, m)
			}
		}
		return out, nil
	})
	def("pick", "pick(obj, key, …)", "An object with only those keys.", func(_ Env, a []any) (any, error) {
		m, _ := first(a).(map[string]any)
		out := map[string]any{}
		for _, k := range flatStrings(a[1:]) {
			if v, ok := m[k]; ok {
				out[k] = v
			}
		}
		return out, nil
	})
	def("omit", "omit(obj, key, …)", "An object without those keys.", func(_ Env, a []any) (any, error) {
		m, _ := first(a).(map[string]any)
		drop := map[string]bool{}
		for _, k := range flatStrings(a[1:]) {
			drop[k] = true
		}
		out := map[string]any{}
		for k, v := range m {
			if !drop[k] {
				out[k] = v
			}
		}
		return out, nil
	})
	def("get", "get(v, \"a.b.0\", fallback?)", "A value at a dotted path, or the fallback.", func(_ Env, a []any) (any, error) {
		sel, err := selector(str(a, 1))
		if err != nil {
			return nil, err
		}
		v, err := sel(first(a))
		if err != nil {
			return nil, err
		}
		if v == nil && len(a) > 2 {
			return a[2], nil
		}
		return v, nil
	})
	def("has", "has(obj, key)", "Whether an object has a key.", func(_ Env, a []any) (any, error) {
		m, _ := first(a).(map[string]any)
		_, ok := m[str(a, 1)]
		return ok, nil
	})
	def("object", "object(k1, v1, k2, v2, …)", "An object from keys and values.", func(_ Env, a []any) (any, error) {
		out := map[string]any{}
		for i := 0; i+1 < len(a); i += 2 {
			out[ToString(a[i])] = a[i+1]
		}
		return out, nil
	})

	// --- lists ---
	def("list", "list(a, b, …)", "A list of the arguments.", func(_ Env, a []any) (any, error) { return emptyList(append([]any{}, a...)), nil })
	def("concat", "concat(list, …)", "Lists joined into one.", func(_ Env, a []any) (any, error) {
		out := []any{}
		for _, v := range a {
			out = append(out, list(v)...)
		}
		return out, nil
	})
	def("flatten", "flatten(list)", "Nested lists flattened one level.", func(_ Env, a []any) (any, error) {
		out := []any{}
		for _, v := range list(first(a)) {
			if l, ok := v.([]any); ok {
				out = append(out, l...)
			} else {
				out = append(out, v)
			}
		}
		return out, nil
	})
	def("unique", "unique(list)", "A list without repeats, in order.", func(_ Env, a []any) (any, error) {
		out := []any{}
		for _, v := range list(first(a)) {
			if !contains(out, v) {
				out = append(out, v)
			}
		}
		return out, nil
	})
	def("reverse", "reverse(list)", "A list backwards.", func(_ Env, a []any) (any, error) {
		in := list(first(a))
		out := make([]any, len(in))
		for i, v := range in {
			out[len(in)-1-i] = v
		}
		return out, nil
	})
	def("sort", "sort(list)", "Numbers or texts in order.", func(_ Env, a []any) (any, error) {
		out := append([]any{}, list(first(a))...)
		sort.SliceStable(out, func(i, j int) bool { c, _ := compare(out[i], out[j]); return c < 0 })
		return out, nil
	})
	def("sort_by", "sort_by(list, x => key | \"field\", desc?)", "A list ordered by a key.", func(_ Env, a []any) (any, error) {
		if err := argN(a, 2, "sort_by"); err != nil {
			return nil, err
		}
		sel, err := selector(a[1])
		if err != nil {
			return nil, err
		}
		out := append([]any{}, list(a[0])...)
		keys := make([]any, len(out))
		for i, v := range out {
			if keys[i], err = sel(v); err != nil {
				return nil, err
			}
		}
		idx := make([]int, len(out))
		for i := range idx {
			idx[i] = i
		}
		desc := len(a) > 2 && Truthy(a[2])
		sort.SliceStable(idx, func(i, j int) bool {
			c, _ := compare(keys[idx[i]], keys[idx[j]])
			if desc {
				return c > 0
			}
			return c < 0
		})
		sorted := make([]any, len(out))
		for i, k := range idx {
			sorted[i] = out[k]
		}
		return sorted, nil
	})
	def("first", "first(list)", "The first item (null if none).", func(_ Env, a []any) (any, error) {
		l := list(first(a))
		if len(l) == 0 {
			return nil, nil
		}
		return l[0], nil
	})
	def("last", "last(list)", "The last item (null if none).", func(_ Env, a []any) (any, error) {
		l := list(first(a))
		if len(l) == 0 {
			return nil, nil
		}
		return l[len(l)-1], nil
	})
	def("slice", "slice(list, start, end?)", "Part of a list.", func(_ Env, a []any) (any, error) {
		l := list(first(a))
		start := clampInt(int(num(a, 1, 0)), len(l))
		end := len(l)
		if len(a) > 2 {
			end = clampInt(int(num(a, 2, float64(len(l)))), len(l))
		}
		if end < start {
			end = start
		}
		return append([]any{}, l[start:end]...), nil
	})
	def("range", "range(n) | range(start, end, step?)", "A list of numbers.", func(_ Env, a []any) (any, error) {
		start, end, step := 0.0, num(a, 0, 0), 1.0
		if len(a) > 1 {
			start, end = num(a, 0, 0), num(a, 1, 0)
		}
		if len(a) > 2 {
			step = num(a, 2, 1)
		}
		if step == 0 || (end-start)/step > 100000 {
			return nil, fmt.Errorf("bad range")
		}
		out := []any{}
		for x := start; (step > 0 && x < end) || (step < 0 && x > end); x += step {
			out = append(out, x)
		}
		return out, nil
	})
	def("index_of", "index_of(list, item)", "Where an item is in a list, -1 if not there.", func(_ Env, a []any) (any, error) {
		for i, v := range list(first(a)) {
			if len(a) > 1 && Equal(v, a[1]) {
				return float64(i), nil
			}
		}
		return float64(-1), nil
	})
	def("map", "map(list, x => expr | \"field\")", "Each item transformed.", func(_ Env, a []any) (any, error) {
		if err := argN(a, 2, "map"); err != nil {
			return nil, err
		}
		sel, err := selector(a[1])
		if err != nil {
			return nil, err
		}
		out := []any{}
		for _, v := range list(a[0]) {
			x, err := sel(v)
			if err != nil {
				return nil, err
			}
			out = append(out, x)
		}
		return out, nil
	})
	def("pluck", "pluck(list, \"field\")", "One field of each item.", func(env Env, a []any) (any, error) { return builtins["map"].fn(env, a) })
	def("filter", "filter(list, x => cond | \"field\", value?)", "The items that pass.", func(_ Env, a []any) (any, error) {
		pred, err := predicate(a, 1)
		if err != nil {
			return nil, err
		}
		out := []any{}
		for _, v := range list(first(a)) {
			ok, err := pred(v)
			if err != nil {
				return nil, err
			}
			if ok {
				out = append(out, v)
			}
		}
		return out, nil
	})
	builtins["where"] = builtin{doc: FuncDoc{Name: "where", Usage: "where(list, \"field\", value)", Summary: "Same as filter with a field and a value."}, fn: builtins["filter"].fn}
	def("find", "find(list, x => cond | \"field\", value?)", "The first item that passes (null if none).", func(_ Env, a []any) (any, error) {
		pred, err := predicate(a, 1)
		if err != nil {
			return nil, err
		}
		for _, v := range list(first(a)) {
			ok, err := pred(v)
			if err != nil {
				return nil, err
			}
			if ok {
				return v, nil
			}
		}
		return nil, nil
	})
	def("any", "any(list, x => cond?)", "Whether any item passes (or is true).", func(_ Env, a []any) (any, error) {
		for _, v := range list(first(a)) {
			ok, err := passes(a, v)
			if err != nil || ok {
				return ok, err
			}
		}
		return false, nil
	})
	def("all", "all(list, x => cond?)", "Whether every item passes (or is true).", func(_ Env, a []any) (any, error) {
		for _, v := range list(first(a)) {
			ok, err := passes(a, v)
			if err != nil || !ok {
				return false, err
			}
		}
		return true, nil
	})
	def("count", "count(list, x => cond?)", "How many items pass (or all).", func(_ Env, a []any) (any, error) {
		n := 0
		for _, v := range list(first(a)) {
			ok := true
			if len(a) > 1 {
				var err error
				if ok, err = passes(a, v); err != nil {
					return nil, err
				}
			}
			if ok {
				n++
			}
		}
		return float64(n), nil
	})
	def("group_by", "group_by(list, x => key | \"field\")", "Items grouped into an object of lists.", func(_ Env, a []any) (any, error) {
		if err := argN(a, 2, "group_by"); err != nil {
			return nil, err
		}
		sel, err := selector(a[1])
		if err != nil {
			return nil, err
		}
		out := map[string]any{}
		for _, v := range list(a[0]) {
			k, err := sel(v)
			if err != nil {
				return nil, err
			}
			ks := ToString(k)
			l, _ := out[ks].([]any)
			out[ks] = append(l, v)
		}
		return out, nil
	})
	def("key_by", "key_by(list, x => key | \"field\")", "An object of the items by a key.", func(_ Env, a []any) (any, error) {
		if err := argN(a, 2, "key_by"); err != nil {
			return nil, err
		}
		sel, err := selector(a[1])
		if err != nil {
			return nil, err
		}
		out := map[string]any{}
		for _, v := range list(a[0]) {
			k, err := sel(v)
			if err != nil {
				return nil, err
			}
			out[ToString(k)] = v
		}
		return out, nil
	})
	def("sum", "sum(list)", "The total of numbers.", func(_ Env, a []any) (any, error) {
		t := 0.0
		for _, v := range list(first(a)) {
			f, _ := toNumber(v)
			t += f
		}
		return t, nil
	})
	def("min", "min(a, b, … | list)", "The smallest number.", func(_ Env, a []any) (any, error) { return extreme(a, -1) })
	def("max", "max(a, b, … | list)", "The largest number.", func(_ Env, a []any) (any, error) { return extreme(a, 1) })
	def("round", "round(n, digits?)", "A number rounded.", func(_ Env, a []any) (any, error) {
		p := math.Pow(10, num(a, 1, 0))
		return math.Round(num(a, 0, 0)*p) / p, nil
	})
	def("floor", "floor(n)", "Rounded down.", func(_ Env, a []any) (any, error) { return math.Floor(num(a, 0, 0)), nil })
	def("ceil", "ceil(n)", "Rounded up.", func(_ Env, a []any) (any, error) { return math.Ceil(num(a, 0, 0)), nil })

	// --- time & randomness ---
	def("now", "now()", "The current time, RFC 3339 (UTC).", func(_ Env, _ []any) (any, error) { return time.Now().UTC().Format(time.RFC3339), nil })
	def("timestamp", "timestamp()", "Seconds since 1970.", func(_ Env, _ []any) (any, error) { return float64(time.Now().Unix()), nil })
	def("uuid", "uuid()", "A random UUID (v4).", func(_ Env, _ []any) (any, error) {
		var b [16]byte
		_, _ = rand.Read(b[:])
		b[6] = b[6]&0x0f | 0x40
		b[8] = b[8]&0x3f | 0x80
		h := hex.EncodeToString(b[:])
		return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:], nil
	})
	def("random_hex", "random_hex(bytes?)", "Random hex text (16 bytes by default), e.g. for passwords.", func(_ Env, a []any) (any, error) {
		n := clampInt(int(num(a, 0, 16)), 256)
		b := make([]byte, max(n, 1))
		_, _ = rand.Read(b)
		return hex.EncodeToString(b), nil
	})
}

func first(a []any) any {
	if len(a) == 0 {
		return nil
	}
	return a[0]
}

func emptyList(l []any) []any {
	if l == nil {
		return []any{}
	}
	return l
}

func passes(a []any, v any) (bool, error) {
	if len(a) < 2 {
		return Truthy(v), nil
	}
	pred, err := predicate(a, 1)
	if err != nil {
		return false, err
	}
	return pred(v)
}

func lengthFn(_ Env, a []any) (any, error) {
	switch x := first(a).(type) {
	case string:
		return float64(len([]rune(x))), nil
	case []any:
		return float64(len(x)), nil
	case map[string]any:
		return float64(len(x)), nil
	case nil:
		return float64(0), nil
	}
	return float64(len(ToString(first(a)))), nil
}

func isEmpty(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return x == ""
	case []any:
		return len(x) == 0
	case map[string]any:
		return len(x) == 0
	}
	return false
}

func clampInt(i, n int) int {
	if i < 0 {
		i += n
	}
	if i < 0 {
		return 0
	}
	if i > n {
		return n
	}
	return i
}

func flatStrings(a []any) []string {
	var out []string
	for _, v := range a {
		if l, ok := v.([]any); ok {
			out = append(out, flatStrings(l)...)
		} else {
			out = append(out, ToString(v))
		}
	}
	return out
}

func extreme(a []any, sign float64) (any, error) {
	items := a
	if len(a) == 1 {
		items = list(a[0])
	}
	var best any
	for _, v := range items {
		f, ok := toNumber(v)
		if !ok {
			continue
		}
		if b, _ := toNumber(best); best == nil || (f-b)*sign > 0 {
			best = f
		}
	}
	return best, nil
}

// deepMerge merges b into a (objects recursively; other values replaced).
func deepMerge(a, b map[string]any) map[string]any {
	out := make(map[string]any, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		if bm, ok := v.(map[string]any); ok {
			if am, ok := out[k].(map[string]any); ok {
				out[k] = deepMerge(am, bm)
				continue
			}
		}
		out[k] = v
	}
	return out
}
