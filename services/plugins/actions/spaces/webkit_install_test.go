package spaces

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tradera/tradera/pkg/webkit"
)

// The commands that put the kit on a computer write it exactly, each under
// the limit on one shell argument.
func TestWebkitInstallCommands(t *testing.T) {
	version := webkitVersion()
	cmds := webkitInstallCommands(version)
	for _, c := range cmds {
		if len(c) > 120<<10 {
			t.Fatalf("a command of %d bytes", len(c))
		}
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("no shell")
	}
	dir := t.TempDir()
	root := filepath.Join(dir, "opt", "tradera", "webkit")
	if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(cmd string) string {
		out, err := exec.Command("sh", "-c", strings.ReplaceAll(cmd, WebkitDir, root)).CombinedOutput()
		if err != nil {
			t.Fatalf("%s: %v %s", cmd[:min(80, len(cmd))], err, out)
		}
		return string(out)
	}
	if !strings.Contains(run(webkitCheckCommand(version)), "stale") {
		t.Fatal("an empty machine is current")
	}
	for _, c := range cmds {
		run(c)
	}
	for _, name := range webkit.Names() {
		want, _, _ := webkit.File(name)
		got, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || string(got) != string(want) {
			t.Fatalf("%s differs (%d vs %d bytes): %v", name, len(got), len(want), err)
		}
	}
	if !strings.Contains(run(webkitCheckCommand(version)), "current") {
		t.Fatal("the installed kit is not current")
	}
}
