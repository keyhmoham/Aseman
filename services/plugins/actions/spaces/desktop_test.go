package spaces

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
	command.Env = append(os.Environ(), "TRADERA_BROWSER_PROFILE="+t.TempDir()+"/profile")
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

// The browser keeps its logins on the project's disk, not in /tmp, so they
// outlive a sleeping or rebuilt computer; an old machine's lock does not block it.
func TestDesktopBrowserKeepsItsLoginsOnTheProjectDisk(t *testing.T) {
	profile := filepath.Join(t.TempDir(), ".tradera", "browser-profile")
	record := filepath.Join(t.TempDir(), "arguments")
	if err := os.MkdirAll(profile, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(profile, "SingletonLock")
	keep := filepath.Join(profile, "Cookies")
	for _, f := range []string{stale, keep} {
		if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	setup := `do_start() { return 0; }
have() { [ "$1" = chromium ]; }
detach() { printf '%s\n' "$@" >` + shellFilePath(record) + `; }
xdotool() { return 0; }
BROWSER_PROFILE=` + shellFilePath(profile)
	if out, err := runDesktopCommand(t, setup, "open", "https://example.com"); err != nil {
		t.Fatalf("open browser: %v\n%s", err, out)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "--user-data-dir="+profile+"\n") {
		t.Fatalf("the browser does not use the project's profile: %s", raw)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("a stale browser lock must be cleared")
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatal("the saved logins must stay")
	}
}

func TestDesktopForgetLoginsErasesTheProfile(t *testing.T) {
	profile := filepath.Join(t.TempDir(), "browser-profile")
	if err := os.MkdirAll(profile, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile, "Cookies"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	setup := "sleep() { return 0; }\nBROWSER_PROFILE=" + shellFilePath(profile)
	if out, err := runDesktopCommand(t, setup, "forget-logins"); err != nil {
		t.Fatalf("forget-logins: %v\n%s", err, out)
	}
	if _, err := os.Stat(profile); !os.IsNotExist(err) {
		t.Fatal("the profile must be erased")
	}
}

func TestTheBrowsersSavedLoginsAreNoFile(t *testing.T) {
	for path, hidden := range map[string]bool{
		"/workspace/.tradera/browser-profile":           true,
		"/workspace/.tradera/browser-profile/Cookies":   true,
		"/workspace/.tradera/browser-profile-notes.txt": false,
		"/workspace/.tradera":                           false,
		"/workspace/index.html":                         false,
	} {
		if inBrowserProfile(path) != hidden {
			t.Errorf("%s: hidden should be %v", path, hidden)
		}
	}
}

// Images, PDFs and the like open in the browser, whatever the image's own
// defaults are (ImageMagick's viewer cannot show a PDF).
func TestDesktopMakesTheBrowserTheDefaultForFiles(t *testing.T) {
	home := t.TempDir()
	setup := "x_up() { return 0; }\nwm_up() { return 0; }\nstream_ok() { return 0; }\nHOME=" + shellFilePath(home) + "\nconfigure_default_apps"
	if out, err := runDesktopCommand(t, setup, "status"); err != nil {
		t.Fatalf("configure: %v\n%s", err, out)
	}
	list, err := os.ReadFile(filepath.Join(home, ".config", "mimeapps.list"))
	if err != nil {
		t.Fatal(err)
	}
	for _, mime := range []string{"application/pdf", "image/png", "image/jpeg", "text/html"} {
		if !strings.Contains(string(list), mime+"=tradera-browser.desktop\n") {
			t.Errorf("%s is not opened with the browser:\n%s", mime, list)
		}
	}
	entry, err := os.ReadFile(filepath.Join(home, ".local", "share", "applications", "tradera-browser.desktop"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(entry), "Exec=/usr/local/bin/tradera-desktop open %U\n") {
		t.Fatalf("the entry must run the desktop's own open:\n%s", entry)
	}
}

func TestDesktopOpensAFileInTheBrowser(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "my report.pdf")
	if err := os.WriteFile(file, []byte("%PDF-1.4"), 0o600); err != nil {
		t.Fatal(err)
	}
	record := filepath.Join(t.TempDir(), "arguments")
	setup := `do_start() { return 0; }
have() { [ "$1" = chromium ]; }
detach() { printf '%s\n' "$@" >` + shellFilePath(record) + `; }
xdotool() { return 0; }`
	if out, err := runDesktopCommand(t, setup, "open", file); err != nil {
		t.Fatalf("open file: %v\n%s", err, out)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Split(strings.TrimSpace(string(raw)), "\n")
	last := args[len(args)-1]
	if !strings.HasPrefix(last, "file://") || !strings.HasSuffix(last, "/my%20report.pdf") {
		t.Fatalf("the file must open as a file: URL, got %q in %v", last, args)
	}
}

// The helpers the desktop writes are Python programs inside the script: a typo
// there would only show up on a running machine.
func TestDesktopPythonHelpersCompile(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	script := string(DesktopScript())
	for _, marker := range []struct{ start, end string }{
		{"<<'PY'\n", "\nPY\n"},
		{"<<'PYCORNERS'\n", "\nPYCORNERS\n"},
		{"<<'PYRC' ", "\nPYRC\n"},
	} {
		_, rest, ok := strings.Cut(script, marker.start)
		if !ok {
			t.Fatalf("no %q block", marker.start)
		}
		if marker.start == "<<'PYRC' " {
			_, rest, _ = strings.Cut(rest, "\n")
		}
		code, _, _ := strings.Cut(rest, marker.end)
		file := filepath.Join(t.TempDir(), "helper.py")
		if err := os.WriteFile(file, []byte(code), 0o600); err != nil {
			t.Fatal(err)
		}
		if out, err := exec.Command(python, "-m", "py_compile", file).CombinedOutput(); err != nil {
			t.Fatalf("%s block does not compile: %v\n%s", marker.start, err, out)
		}
	}
}

func TestDesktopWritesItsThemeAndOpenboxSettings(t *testing.T) {
	home := t.TempDir()
	setup := "x_up() { return 0; }\nwm_up() { return 0; }\nstream_ok() { return 0; }\nHOME=" + shellFilePath(home) +
		"\nTHEME_DIR=" + shellFilePath(filepath.Join(home, ".themes/Tradera/openbox-3")) + "\nwrite_theme\nwrite_gtk_settings"
	if out, err := runDesktopCommand(t, setup, "status"); err != nil {
		t.Fatalf("write theme: %v\n%s", err, out)
	}
	theme, err := os.ReadFile(filepath.Join(home, ".themes/Tradera/openbox-3/themerc"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"window.active.title.bg: Flat Solid", "window.handle.width: 0", "osd.bg: Flat Solid"} {
		if !strings.Contains(string(theme), want) {
			t.Errorf("theme lacks %q", want)
		}
	}
	// Nothing in the theme repaints over VNC: no gradients.
	if strings.Contains(string(theme), "Gradient") {
		t.Error("the theme must stay flat")
	}
	gtk, err := os.ReadFile(filepath.Join(home, ".config/gtk-3.0/settings.ini"))
	if err != nil || !strings.Contains(string(gtk), "gtk-application-prefer-dark-theme=1") || !strings.Contains(string(gtk), "gtk-enable-animations=false") {
		t.Fatalf("gtk settings: %v\n%s", err, gtk)
	}
}

// Files runs with a small preload that drops the root warning and the free-space
// figure. It is C inside the script; it is built on the machine, so check it builds.
func TestDesktopFilesPreloadBuilds(t *testing.T) {
	cc, err := exec.LookPath("cc")
	if err != nil {
		t.Skip("no C compiler")
	}
	_, rest, ok := strings.Cut(string(DesktopScript()), "<<'CSHIM'\n")
	if !ok {
		t.Fatal("no preload source in the desktop script")
	}
	code, _, _ := strings.Cut(rest, "\nCSHIM\n")
	dir := t.TempDir()
	src := filepath.Join(dir, "files.c")
	if err := os.WriteFile(src, []byte(code), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"-shared", "-fPIC", "-o", filepath.Join(dir, "files.so"), src}
	if runtime.GOOS != "darwin" {
		args = append(args, "-ldl")
	}
	if out, err := exec.Command(cc, args...).CombinedOutput(); err != nil {
		t.Fatalf("preload does not build: %v\n%s", err, out)
	}
}
