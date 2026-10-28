package governance

import (
	"fmt"
	"sort"
	"strings"

	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/governance/models/scan"
)

// Deterministic inspection of what is about to leave the node. It looks for
// credentials and payment card numbers, not for personal information in
// general: a matcher for every email address or phone number would block
// ordinary work and turn a boundary into a false assurance. A finding names
// only its category and where it was; the matched value is never copied into
// an error, a log or the audit trail.
//
// A person's own secret, named as {{secret:name}}, passes: it is put in after
// this check, by the gate, on purpose.

// leaves reports a request whose arguments leave the node.
func leaves(req gate.Request) bool {
	switch req.Effect {
	case gate.EffectSend, gate.EffectExternal, gate.EffectPay, gate.EffectSign:
		return true
	}
	return req.Kind == gate.KindMCP || req.Kind == gate.KindChannel
}

// inspectOutbound returns a finding ("a GitHub token in args.body") or "".
func (s *Service) inspectOutbound(req gate.Request) string {
	if !leaves(req) {
		return ""
	}
	var found []string
	walk := func(where, text string) {
		for _, c := range scan.Findings(text) {
			found = append(found, c+" in "+where)
		}
	}
	if len(req.Args) > 0 {
		walkStrings(decodeJSON(req.Args), "args", walk)
	}
	if req.Command != "" {
		walk("command", req.Command)
	}
	if len(found) == 0 {
		return ""
	}
	sort.Strings(found)
	return "the action was not sent: it carries " + strings.Join(dedupe(found), "; ") +
		". Remove it, or ask the person to enter it through a secret box (secret_request) and use {{secret:name}}."
}

func walkStrings(v any, at string, visit func(string, string)) {
	switch t := v.(type) {
	case string:
		visit(at, t)
	case map[string]any:
		for k, item := range t {
			walkStrings(item, at+"."+k, visit)
		}
	case []any:
		for i, item := range t {
			walkStrings(item, fmt.Sprintf("%s[%d]", at, i), visit)
		}
	}
}

func dedupe(list []string) []string {
	out := list[:0]
	for i, v := range list {
		if i == 0 || v != list[i-1] {
			out = append(out, v)
		}
	}
	return out
}
