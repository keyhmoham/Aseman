package helper

import (
	"regexp"
	"strings"

	"github.com/tradera/tradera/pkg/errs"
)

const (
	HandleMin = 3
	HandleMax = 30
)

var handlePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*[a-z0-9]$`)

// reservedHandles belong to the platform itself.
var reservedHandles = map[string]bool{"tradera": true, "lead": true}

// NormalizeHandle trims, drops a leading "@" and lowercases a username, then
// checks it: HandleMin–HandleMax characters of a-z, 0-9, "." "_" "-", starting
// and ending with a letter or digit. Usernames are public and shown as @handle,
// so spaces, symbols and look-alike case variants are refused.
func NormalizeHandle(raw string) (string, error) {
	h := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "@"))
	if len(h) < HandleMin || len(h) > HandleMax {
		return "", errs.InvalidArgument("username must be 3–30 characters")
	}
	if !handlePattern.MatchString(h) {
		return "", errs.InvalidArgument("username may only use letters, numbers, \".\", \"_\" and \"-\", and must start and end with a letter or number")
	}
	if reservedHandles[h] {
		return "", errs.InvalidArgument("username @" + h + " is reserved")
	}
	return h, nil
}

// SanitizeHandle turns arbitrary text (e.g. an email's local part) into a
// valid username base by replacing anything else with "_".
func SanitizeHandle(raw string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(raw)) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	h := strings.Trim(b.String(), "._-")
	if len(h) > HandleMax-4 {
		h = h[:HandleMax-4]
	}
	for len(h) < HandleMin {
		h += "0"
	}
	return h
}
