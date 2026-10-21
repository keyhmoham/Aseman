package tools

import (
	"regexp"
	"strings"
	"testing"
)

func TestStopPatternMatchesOnlyTheRunningBackend(t *testing.T) {
	const bot = "68572f88fe843b81f156e520359ba249"
	pattern := stopPattern(bot)
	if strings.HasPrefix(pattern, "-") {
		t.Fatalf("pkill would read %q as an option", pattern)
	}
	re := regexp.MustCompile(pattern)
	if !re.MatchString("node /opt/aseman-tool-runtime/server.mjs --tool " + bot) {
		t.Fatal("the running backend is not matched")
	}
	// The shell running the restart holds the pattern on its command line.
	if re.MatchString("sh -c cd /x && (pkill -f '" + pattern + "' 2>/dev/null; true)") {
		t.Fatal("the restart would kill its own shell")
	}
	if re.MatchString("node /opt/aseman-tool-runtime/server.mjs --tool other" + bot) {
		t.Fatal("another tool's backend is matched")
	}
}
