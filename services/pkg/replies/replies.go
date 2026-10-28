// Package replies reads the tappable answers an agent offers at the end of a
// message: a last line <replies>first | second | third</replies>. The chat
// shows them as chips, Slack and Teams as buttons; the line itself is not
// shown.
package replies

import (
	"regexp"
	"strings"
)

// Max is how many replies are shown, and MaxLen how long each may be.
const (
	Max    = 3
	MaxLen = 40
)

var line = regexp.MustCompile(`(?s)\n?[ \t]*<replies>(.*?)</replies>[ \t]*$`)

// Parse splits a message into what it says and the replies it offers.
func Parse(body string) (string, []string) {
	trimmed := strings.TrimRight(body, " \t\n")
	m := line.FindStringSubmatchIndex(trimmed)
	if m == nil {
		return body, nil
	}
	var out []string
	for _, r := range strings.Split(trimmed[m[2]:m[3]], "|") {
		r = strings.TrimSpace(r)
		if r == "" || len(out) == Max {
			continue
		}
		if len([]rune(r)) > MaxLen {
			r = strings.TrimSpace(string([]rune(r)[:MaxLen]))
		}
		out = append(out, r)
	}
	return strings.TrimRight(trimmed[:m[0]], " \t\n"), out
}
