// Package scan finds credentials and payment card numbers in text: the
// governance gate's outbound check, and the redaction of anything that
// records what people typed (demonstrations, channels, the audit trail).
// It detects credentials, not personal information in general.
package scan

import (
	"regexp"
)

// secretRef is a person's vault secret named by placeholder, which passes.
var secretRef = regexp.MustCompile(`\{\{\s*secret:([A-Za-z0-9_.-]{1,64})\s*\}\}`)

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

// Redact hides every credential and card number in text.
func Redact(text string) string {
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
