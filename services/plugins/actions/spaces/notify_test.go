package spaces

import (
	"strings"
	"testing"
)

// A notification is one plain line: who, then the start of what they said.
func TestNoticeBody(t *testing.T) {
	cases := []struct {
		name, sender, body string
		attachments        int
		want               string
	}{
		{"plain", "Researcher", "Here is the report.", 0, "Researcher: Here is the report."},
		{"markdown is not shown", "Engineer", "## Done\n\n**Built** the `api` and [the docs](https://x.test/docs).", 0, "Engineer: Done Built the api and the docs."},
		{"a file with no words", "Ada", "", 1, "Ada: Sent a file"},
		{"several files", "Ada", "  ", 3, "Ada: Sent files"},
		{"nothing at all", "", "", 0, "Sent a message"},
		{"no sender known", "", "hello", 0, "hello"},
		{"a shared post", "Ada", "look\n\n:::post {\"id\":\"p\",\"author_id\":\"a\",\"name\":\"Bob\",\"body\":\"**Long** BTC\"}", 0, "Ada: look Forwarded post from Bob: Long BTC"},
	}
	for _, c := range cases {
		if got := noticeBody(c.sender, c.body, c.attachments); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	long := noticeBody("Writer", strings.Repeat("word ", 100), 0)
	if !strings.HasSuffix(long, "…") || len([]rune(long)) > len("Writer: ")+160 {
		t.Errorf("a long message is cut short: %d runes", len([]rune(long)))
	}
}
