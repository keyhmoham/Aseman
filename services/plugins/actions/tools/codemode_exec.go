package tools

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/dop251/goja"
	"github.com/aseman/aseman/pkg/errs"
)

// runCodeModeJS executes model-written Code Mode JavaScript in an isolated
// goja VM. The sandbox has no network; it only sees codemode.spec() and
// (for execute) codemode.request(). Async/await in the usual Cloudflare
// snippets is stripped so host calls stay synchronous.
func runCodeModeJS(code string, spec map[string]any, request func(CodeModeRequest) (any, error)) (any, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return nil, errs.InvalidArgument("code is required")
	}
	code = normalizeCodeModeJS(code)

	vm := goja.New()
	vm.SetFieldNameMapper(goja.TagFieldNameMapper("json", true))

	codemode := vm.NewObject()
	_ = codemode.Set("spec", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(spec)
	})
	if request != nil {
		_ = codemode.Set("request", func(call goja.FunctionCall) goja.Value {
			if len(call.Arguments) < 1 {
				panic(vm.ToValue("codemode.request(options) needs an options object"))
			}
			var opts CodeModeRequest
			raw, err := json.Marshal(call.Arguments[0].Export())
			if err != nil {
				panic(vm.ToValue(err.Error()))
			}
			if err := json.Unmarshal(raw, &opts); err != nil {
				panic(vm.ToValue("invalid request options: " + err.Error()))
			}
			out, err := request(opts)
			if err != nil {
				panic(vm.ToValue(err.Error()))
			}
			return vm.ToValue(out)
		})
	} else {
		_ = codemode.Set("request", func(call goja.FunctionCall) goja.Value {
			panic(vm.ToValue("codemode.request is only available in execute, not search"))
		})
	}
	_ = vm.Set("codemode", codemode)

	// Evaluate the user program as a function and call it.
	wrapped := fmt.Sprintf(`(function(){
  var __fn = (%s);
  if (typeof __fn !== "function") {
    throw new Error("code must be a function, e.g. () => { ... } or async () => { ... }");
  }
  return __fn();
})()`, code)

	v, err := vm.RunString(wrapped)
	if err != nil {
		return nil, errs.InvalidArgument(cleanGojaErr(err))
	}
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil, nil
	}
	exported := v.Export()
	// Reject unsettled thenables (async without our strip, or real Promises).
	if m, ok := exported.(map[string]any); ok {
		if _, hasThen := m["then"]; hasThen {
			return nil, errs.InvalidArgument("code returned a Promise; write a sync function or use await (stripped to sync host calls)")
		}
	}
	return exported, nil
}

var reAwait = regexp.MustCompile(`\bawait\s+`)

func normalizeCodeModeJS(code string) string {
	// Strip async before function forms (Go regexp has no lookahead).
	code = strings.ReplaceAll(code, "async function", "function")
	code = strings.ReplaceAll(code, "async()", "()")
	code = strings.ReplaceAll(code, "async (", "(")
	code = strings.ReplaceAll(code, "async ()", "()")
	// "async () =>" / "async (opts) =>" already covered by replacing "async (".
	code = reAwait.ReplaceAllString(code, "")
	return strings.TrimSpace(code)
}

func cleanGojaErr(err error) string {
	s := err.Error()
	s = strings.TrimPrefix(s, "GoError: ")
	if i := strings.Index(s, " at "); i > 0 {
		s = s[:i]
	}
	return s
}
