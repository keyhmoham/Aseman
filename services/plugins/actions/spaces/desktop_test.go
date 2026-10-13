package spaces

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The sandbox image carries the same desktop program the node writes onto older
// machines; they must not drift apart.
func TestSandboxImageCarriesTheNodesDesktopScript(t *testing.T) {
	image, err := os.ReadFile("../../../../deploy/sandbox-computer/tradera-desktop")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(image, DesktopScript()) {
		t.Fatal("deploy/sandbox-computer/tradera-desktop differs from spaces/desktop.sh; copy one over the other")
	}
}

// Exercise the real command dispatch without depending on an X server on CI.
func runDesktopCommand(t *testing.T, setup string, args ...string) (string, error) {
	t.Helper()
	script := string(DesktopScript())
	prefix, dispatch, ok := strings.Cut(script, "\ncmd=")
	if !ok {
		t.Fatal("desktop command dispatch missing")
	}
	program := prefix + "\nSTATE=" + shellFilePath(t.TempDir()) + "\n" + setup + "\ncmd=" + dispatch
	command := exec.Command("bash", append([]string{"-c", program, "tradera-desktop"}, args...)...)
	out, err := command.CombinedOutput()
	return string(out), err
}

func TestDesktopBrowserAliasesUseSafeLaunchFlags(t *testing.T) {
	for _, alias := range []string{"chrome", "chromium", "chromium-browser", "google-chrome", "browser", "https://example.com"} {
		t.Run(alias, func(t *testing.T) {
			record := filepath.Join(t.TempDir(), "arguments")
			setup := `do_start() { return 0; }
have() { [ "$1" = chromium ]; }
detach() { printf '%s\n' "$@" >` + shellFilePath(record) + `; }
xdotool() { return 0; }`
			args := []string{"open", alias}
			if !strings.HasPrefix(alias, "https:") {
				args = append(args, "https://example.com")
			}
			out, err := runDesktopCommand(t, setup, args...)
			if err != nil {
				t.Fatalf("open browser: %v\n%s", err, out)
			}
			raw, err := os.ReadFile(record)
			if err != nil {
				t.Fatal(err)
			}
			arguments := strings.Split(strings.TrimSpace(string(raw)), "\n")
			if arguments[0] != "chromium" || arguments[len(arguments)-1] != "https://example.com" {
				t.Fatalf("wrong browser command: %v", arguments)
			}
			for _, flag := range []string{"--no-sandbox", "--disable-dev-shm-usage", "--password-store=basic"} {
				if !strings.Contains(string(raw), flag+"\n") {
					t.Fatalf("missing %s in %v", flag, arguments)
				}
			}
			if strings.Count(string(raw), "https://example.com") != 1 {
				t.Fatal("the target must not be passed twice")
			}
		})
	}
}

func TestDesktopDoesNotClaimBrowserOpenedWithoutAWindow(t *testing.T) {
	setup := `do_start() { return 0; }
have() { [ "$1" = chromium ]; }
detach() { return 0; }
xdotool() { return 1; }
sleep() { return 0; }
LOG=/dev/null`
	out, err := runDesktopCommand(t, setup, "open", "chromium")
	if err == nil || !strings.Contains(out, "did not open a desktop window") || strings.Contains(out, "opened about:blank") {
		t.Fatalf("a failed launch must report failure: %v\n%s", err, out)
	}
}

func TestDesktopLaunchDoesNotDuplicateApplicationName(t *testing.T) {
	record := filepath.Join(t.TempDir(), "arguments")
	setup := `do_start() { return 0; }
have() { [ "$1" = xterm ]; }
detach() { printf '%s\n' "$@" >` + shellFilePath(record) + `; }`
	out, err := runDesktopCommand(t, setup, "open", "xterm", "-title", "Project terminal")
	if err != nil {
		t.Fatalf("open terminal: %v\n%s", err, out)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "xterm\n-title\nProject terminal\n" {
		t.Fatalf("wrong application arguments: %q", raw)
	}
}

func TestDesktopMissingApplicationFails(t *testing.T) {
	out, err := runDesktopCommand(t, "do_start() { return 0; }", "open", "tradera-test-missing-app")
	if err == nil || !strings.Contains(out, "application not found") {
		t.Fatalf("missing app must not be reported as started: %v\n%s", err, out)
	}
}

func TestDesktopStartRequiresWindowManagerAndDock(t *testing.T) {
	for _, failing := range []string{"wm_up", "dock_up"} {
		t.Run(failing, func(t *testing.T) {
			setup := `ensure_packages() { return 0; }
novnc_dir() { echo /tmp; }
x_up() { return 0; }
wm_up() { return 0; }
dock_up() { return 0; }
configure_dock() { return 0; }
pgrep() { return 0; }
xsetroot() { return 0; }
sleep() { return 0; }
LOG=/dev/null
` + failing + "() { return 1; }"
			out, err := runDesktopCommand(t, setup, "start")
			if err == nil || strings.Contains(out, "DESKTOP_PASSWORD:") {
				t.Fatalf("desktop without %s must not be ready: %v\n%s", failing, err, out)
			}
		})
	}
}

func TestDesktopScriptIsValidShell(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if out, err := exec.Command("bash", "-n", "desktop.sh").CombinedOutput(); err != nil {
		t.Fatalf("desktop.sh: %v\n%s", err, out)
	}
}
