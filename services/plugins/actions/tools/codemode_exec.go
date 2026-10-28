package tools

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/dop251/goja"
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
			opts, err := codeModeOptions(call.Arguments[0].Export())
			if err != nil {
				panic(vm.ToValue(err.Error()))
			}
			out, err := request(opts)
			if err != nil {
				panic(vm.ToValue(err.Error()))
			}
			return vm.ToValue(out)
		})
		// codemode.batch runs independent calls at the same time (several
		// agents, apps or commands) and returns each one's outcome in order.
		_ = codemode.Set("batch", func(call goja.FunctionCall) goja.Value {
			var items []any
			if len(call.Arguments) > 0 {
				items, _ = call.Arguments[0].Export().([]any)
			}
			if len(items) == 0 {
				panic(vm.ToValue("codemode.batch(requests) needs an array of request options"))
			}
			reqs := make([]CodeModeRequest, len(items))
			for i, item := range items {
				opts, err := codeModeOptions(item)
				if err != nil {
					panic(vm.ToValue(fmt.Sprintf("request %d: %v", i, err)))
				}
				reqs[i] = opts
			}
			return vm.ToValue(runCodeModeBatch(reqs, request))
		})
	} else {
		unavailable := func(call goja.FunctionCall) goja.Value {
			panic(vm.ToValue("codemode.request and codemode.batch are only available in execute, not search"))
		}
		_ = codemode.Set("request", unavailable)
		_ = codemode.Set("batch", unavailable)
	}
	_ = vm.Set("codemode", codemode)
	// Host calls are synchronous (await is stripped), so the usual
	// Promise.all / Promise.resolve wrappers just pass their values through.
	if _, err := vm.RunString(`Promise.all = function (a) { return Array.from(a); };
Promise.resolve = function (v) { return v; };`); err != nil {
		return nil, err
	}

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

// How many calls of one codemode.batch run at a time.
const codeModeBatchParallel = 8

func codeModeOptions(v any) (CodeModeRequest, error) {
	var opts CodeModeRequest
	raw, err := json.Marshal(v)
	if err != nil {
		return opts, err
	}
	if err := json.Unmarshal(raw, &opts); err != nil {
		return opts, fmt.Errorf("invalid request options: %w", err)
	}
	return opts, nil
}

// runCodeModeBatch runs the calls concurrently; each outcome is
// {ok: true, result} or {ok: false, error}, so one failure does not lose the
// others' results.
func runCodeModeBatch(reqs []CodeModeRequest, request func(CodeModeRequest) (any, error)) []any {
	out := make([]any, len(reqs))
	slots := make(chan struct{}, codeModeBatchParallel)
	var wg sync.WaitGroup
	for i, opts := range reqs {
		wg.Add(1)
		slots <- struct{}{}
		go func(i int, opts CodeModeRequest) {
			defer func() {
				if r := recover(); r != nil {
					out[i] = map[string]any{"ok": false, "error": fmt.Sprint(r)}
				}
				<-slots
				wg.Done()
			}()
			result, err := request(opts)
			if err != nil {
				out[i] = map[string]any{"ok": false, "error": err.Error()}
				return
			}
			out[i] = map[string]any{"ok": true, "result": result}
		}(i, opts)
	}
	wg.Wait()
	return out
}
