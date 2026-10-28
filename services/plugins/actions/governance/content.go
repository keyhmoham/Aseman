package governance

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
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

type detector struct {
	category string
	re       *regexp.Regexp
}

var detectors = []detector{
	{"private key", regexp.MustCompile(`-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----`)},
	{"cloud access key", regexp.MustCompile(`\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`)},
	{"GitHub token", regexp.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b`)},
	{"Slack token", regexp.MustCompile(`\bxox[abprs]-[A-Za-z0-9-]{10,}`)},
	{"payment API key", regexp.MustCompile(`\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}`)},
	{"Google API key", regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}\b`)},
	{"model API key", regexp.MustCompile(`\bsk-(?:proj-|ant-[a-z0-9]+-)?[A-Za-z0-9_-]{24,}`)},
	{"Aseman key", regexp.MustCompile(`\b(?:dk|pk)_live_[A-Za-z0-9]{16,}`)},
	{"signed token", regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`)},
	{"password in a connection string", regexp.MustCompile(`\b[a-z][a-z0-9+.-]{1,20}://[^\s:/@'"]+:[^\s@/'"]{3,}@[^\s/'"]+`)},
}

// cardCandidate is 13 to 19 digits, optionally grouped by spaces or dashes.
var cardCandidate = regexp.MustCompile(`\b(?:\d[ -]?){12,18}\d\b`)

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
		for _, c := range Findings(text) {
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

// Findings are the categories of credentials and card numbers in text.
func Findings(text string) []string {
	text = secretRef.ReplaceAllString(text, "")
	var out []string
	for _, d := range detectors {
		if d.re.MatchString(text) {
			out = append(out, d.category)
		}
	}
	for _, m := range cardCandidate.FindAllString(text, -1) {
		if luhn(m) {
			out = append(out, "payment card number")
			break
		}
	}
	return out
}

// redactFindings hides every credential and card number in text.
func redactFindings(text string) string {
	for _, d := range detectors {
		text = d.re.ReplaceAllString(text, "[redacted "+d.category+"]")
	}
	return cardCandidate.ReplaceAllStringFunc(text, func(m string) string {
		if luhn(m) {
			return "[redacted card]"
		}
		return m
	})
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

// luhn checks a card number's check digit, and that it looks like a card
// (a known leading digit) rather than any long number.
func luhn(candidate string) bool {
	digits := make([]int, 0, 19)
	for _, r := range candidate {
		if r >= '0' && r <= '9' {
			digits = append(digits, int(r-'0'))
		}
	}
	if len(digits) < 13 || len(digits) > 19 {
		return false
	}
	switch digits[0] {
	case 2, 3, 4, 5, 6:
	default:
		return false
	}
	allSame := true
	for _, d := range digits {
		if d != digits[0] {
			allSame = false
		}
	}
	if allSame {
		return false
	}
	sum, double := 0, false
	for i := len(digits) - 1; i >= 0; i-- {
		d := digits[i]
		if double {
			d *= 2
			if d > 9 {
				d -= 9
			}
		}
		sum += d
		double = !double
	}
	return sum%10 == 0
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
