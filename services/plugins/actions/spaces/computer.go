package spaces

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"path"
	"slices"
	"strings"
)

func computerActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "computer", Summary: "Read/start/stop a workspace computer", Handler: s.computerAction},
		helper.Action{Namespace: "spaces", Name: "sandbox_files", Summary: "Browse and edit workspace files", Handler: s.sandboxFilesAction},
		helper.Action{Namespace: "spaces", Name: "desktop_install", Summary: "Start a VNC desktop on the workspace computer", Handler: s.desktopInstall},
		helper.Action{Namespace: "spaces", Name: "desktop_uninstall", Summary: "Stop and remove the workspace desktop", Handler: s.desktopUninstall},
	}
}
func (s *Service) computerScope(ctx context.Context, req *api.ActionRequest, write bool) (identity.ID, error) {
	var in struct {
		Space string `json:"space"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return identity.ID{}, e
	}
	id, e := identity.Parse(in.Space)
	if e != nil {
		return id, e
	}
	perm := permission.RoomRead
	if write {
		perm = permission.RoomSend
	}
	return id, s.Can(ctx, id, identity.ID{}, req.Caller.ID, perm)
}
func (s *Service) computerAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Operation string `json:"operation"`
		// Since is the revision a watch already has (see computerStatus).
		Since string `json:"since"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	read := in.Operation == "" || in.Operation == "status" || in.Operation == "watch"
	sp, e := s.computerScope(ctx, req, !read)
	if e != nil {
		return nil, e
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	switch in.Operation {
	case "", "status":
	case "watch":
		// A long poll: it answers as soon as the computer changes, so a
		// screen showing it is live without asking every few seconds.
		out, e := s.watchComputer(ctx, sp, in.Since)
		if e != nil {
			return nil, e
		}
		return helper.JSON(out)
	case "provision", "wake":
		done := s.computerBusy(sp, "waking")
		if e = s.requireFundsForComputer(ctx, sp, req.Caller.ID); e == nil {
			_, e = s.SandboxStart(ctx, sp)
		}
		done()
	case "keepalive":
		// Someone has the desktop open: that counts as activity, but never
		// wakes a machine that is asleep.
		if id, ok := s.sandboxBotID(ctx, sp); ok {
			if rec, ge := s.Bots.GetBot(ctx, id); ge == nil && rec.Status == bot.StatusRunning {
				s.touch(sp)
			}
		}
	case "sleep":
		done := s.computerBusy(sp, "sleeping")
		_, e = s.SandboxStop(ctx, sp)
		done()
	case "forget_logins":
		e = s.forgetBrowserLogins(ctx, sp)
	case "replace":
		done := s.computerBusy(sp, "replacing")
		if _, ok := s.sandboxBotID(ctx, sp); !ok {
			_, e = s.SandboxStart(ctx, sp)
		} else {
			var stopped *bot.Bot
			stopped, e = s.SandboxStop(ctx, sp)
			if e == nil {
				_, e = s.Bots.Rebuild(ctx, stopped.ID, s.sandboxImage())
			}
		}
		done()
	default:
		return nil, errs.InvalidArgument("invalid computer operation")
	}
	if e != nil {
		return nil, e
	}
	out, e := s.computerStatus(ctx, sp, true)
	if e != nil {
		return nil, e
	}
	return helper.JSON(out)
}

// computerStatus describes a project's computer: its state as people see it
// (see computerState), its size and whether its desktop was started. Its
// rev changes whenever any of what a screen shows of it does. The desktop's
// password is not part of it: opening the desktop (desktop_install) gives it.
func (s *Service) computerStatus(ctx context.Context, sp identity.ID, probe bool) (map[string]any, error) {
	st, e := s.sandboxStatus(ctx, sp, probe)
	if e != nil {
		return nil, e
	}
	running := st["status"] == bot.StatusRunning || st["status"] == "running"
	desktop := map[string]any{"installed": false}
	if m, e := s.M.Get(ctx, sp); e == nil {
		if g, ok := m.Tree["desktop"].(map[string]any); ok {
			desktop = map[string]any{"installed": g["installed"] == true}
		}
	}
	op := s.computerOp(sp)
	state := computerState(st["status"], op)
	profile := s.sandboxResourceProfile(ctx)
	return map[string]any{
		"state": state, "busy": op, "rev": fmt.Sprintf("%s|%v|%v", state, st["status"], desktop["installed"]),
		"status": st["status"], "running": running, "vm_id": st["vm_id"], "vm_type": st["vm_type"], "bot_id": st["bot_id"],
		"image": s.sandboxImage(), "cpu": profile.CPU, "memory_mb": profile.Memory, "disk_mb": profile.Disk,
		"idle_timeout_sec": int64(sandboxIdleTTL.Seconds()), "desktop": desktop,
	}, nil
}

// browserProfileDir is where the desktop's browser keeps its cookies and
// logins, on the project's own disk so they outlive a sleeping or rebuilt
// computer (see desktop.sh). It is a live session: no file tool shows it.
const browserProfileDir = "/workspace/.tradera/browser-profile"

// inBrowserProfile reports whether a cleaned workspace path is the browser's
// saved logins or inside them.
func inBrowserProfile(target string) bool {
	return target == browserProfileDir || strings.HasPrefix(target, browserProfileDir+"/")
}

// forgetBrowserLogins erases the browser's saved logins, awake or asleep.
func (s *Service) forgetBrowserLogins(ctx context.Context, sp identity.ID) error {
	id, ok := s.sandboxBotID(ctx, sp)
	if !ok {
		return nil // no computer yet: nothing was ever saved
	}
	rec, e := s.Bots.GetBot(ctx, id)
	if e != nil {
		return e
	}
	if rec.Status == bot.StatusRunning {
		out, e := s.SandboxExec(ctx, sp, desktopInstallCommand()+" && tradera-desktop forget-logins")
		if e != nil {
			return e
		}
		if !strings.HasPrefix(out, "exit=0") {
			return errs.New(errs.CodeUnavailable, fmt.Sprint(out))
		}
		return nil
	}
	writer, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(vmm.WorkspaceWriter)
	if !ok {
		return errs.New(errs.CodeUnavailable, "Start the computer first: this provider cannot erase files while it sleeps.")
	}
	_ = s.Bots.EnsureVM(ctx, rec)
	if e := writer.DeleteWorkspace(ctx, rec.VMID, strings.TrimPrefix(browserProfileDir, "/workspace/")); e != nil && errs.CodeOf(e) != errs.CodeNotFound {
		return e
	}
	return nil
}

func workspacePath(p string) (string, error) {
	clean := path.Clean("/workspace/" + strings.TrimPrefix(p, "/"))
	if clean != "/workspace" && !strings.HasPrefix(clean, "/workspace/") {
		return "", errs.InvalidArgument("path is outside the workspace")
	}
	return clean, nil
}
func (s *Service) sandboxFilesAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Operation string `json:"operation"`
		Path      string `json:"path"`
		Content   string `json:"content"`
		Base64    string `json:"data_base64"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	write := in.Operation != "list" && in.Operation != "read"
	sp, e := s.computerScope(ctx, req, write)
	if e != nil {
		return nil, e
	}
	target, e := workspacePath(in.Path)
	if e != nil {
		return nil, e
	}
	if inBrowserProfile(target) {
		return nil, errs.Permission("the browser's saved logins are not files you can open")
	}
	// An agent's request carries its turn's limits (a person's has none).
	if policy := vmm.ExecutionFrom(ctx); policy.NoSandbox {
		return nil, errs.Permission("sandbox access is disabled for this request")
	} else if policy.NoMemory && (strings.Contains(target, "AGENTS.md") || strings.Contains(target, "/.tradera/")) {
		return nil, errs.Permission("saved space memory is disabled for this request")
	}
	// The agents' notes are in their memory server, not in the sandbox.
	if resp, ok, e := s.memoryNotes(ctx, req, sp, in.Operation, target, in.Content, in.Base64); ok || e != nil {
		return resp, e
	}
	id, ok := s.sandboxBotID(ctx, sp)
	if !ok {
		// A project that has never had a computer simply has no files yet — to
		// an agent and to a person alike. Looking is no reason to create one.
		if !write {
			if in.Operation == "list" {
				return helper.JSON(map[string]any{"items": []any{}})
			}
			return helper.JSON(map[string]any{"ok": false, "missing": true, "error": "That file does not exist."})
		}
		return helper.JSON(map[string]any{"ok": false, "asleep": true, "error": "The computer has not been started yet."})
	}
	rec, e := s.Bots.GetBot(ctx, id)
	if e != nil {
		return nil, e
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "computer provider unavailable")
	}
	if !write {
		// Tell the provider what this computer was made from, so it can read
		// the files of a stopped one after a node restart.
		_ = s.Bots.EnsureVM(ctx, rec)
		reader, ok := vm.(vmm.WorkspaceReader)
		var readErr error
		if ok {
			if in.Operation == "list" {
				entries, e := reader.ListWorkspace(ctx, rec.VMID, strings.TrimPrefix(strings.TrimPrefix(target, "/workspace"), "/"))
				if e == nil {
					if target == path.Dir(browserProfileDir) {
						entries = slices.DeleteFunc(entries, func(en vmm.WorkspaceEntry) bool { return path.Join(target, en.Name) == browserProfileDir })
					}
					return helper.JSON(map[string]any{"items": entries})
				}
				if errs.CodeOf(e) == errs.CodeNotFound {
					// A project nobody has written to yet has no files: that is
					// an empty list, not a missing folder.
					if target == "/workspace" {
						return helper.JSON(map[string]any{"items": []any{}})
					}
					return helper.JSON(map[string]any{"ok": false, "missing": true, "error": "That folder does not exist."})
				}
				readErr = e
			} else {
				b, e := reader.ReadWorkspace(ctx, rec.VMID, strings.TrimPrefix(strings.TrimPrefix(target, "/workspace"), "/"))
				if e == nil {
					return helper.JSON(map[string]any{"content": string(b), "data_base64": base64.StdEncoding.EncodeToString(b), "size": len(b)})
				}
				// A file that is not there is an answer; it is no reason to start the computer.
				if errs.CodeOf(e) == errs.CodeNotFound {
					return helper.JSON(map[string]any{"ok": false, "missing": true, "error": "That file does not exist."})
				}
				readErr = e
			}
		}
		if rec.Status != bot.StatusRunning {
			if readErr != nil {
				// The provider can read a sleeping computer's files and failed
				// to: say why, here and in the node's log.
				s.L.Warn("read sleeping project files", "space", sp.String(), "path", target, "error", readErr)
				return helper.JSON(map[string]any{"ok": false, "asleep": true, "unreadable": true, "error": "The files could not be read while the machine is asleep: " + readErr.Error()})
			}
			return helper.JSON(map[string]any{"ok": false, "asleep": true, "error": "This provider cannot read sleeping files."})
		}
	}
	if rec.Status != bot.StatusRunning {
		// Saving or deleting a file does not need the computer awake when the
		// provider can change the stored files directly.
		if writer, ok := vm.(vmm.WorkspaceWriter); ok && (in.Operation == "write" || in.Operation == "delete") {
			rel := strings.TrimPrefix(strings.TrimPrefix(target, "/workspace"), "/")
			var werr error
			if in.Operation == "delete" {
				werr = writer.DeleteWorkspace(ctx, rec.VMID, rel)
			} else {
				data := []byte(in.Content)
				if in.Base64 != "" {
					decoded, derr := base64.StdEncoding.DecodeString(in.Base64)
					if derr != nil {
						return nil, errs.InvalidArgument("invalid file data")
					}
					data = decoded
				}
				werr = writer.WriteWorkspace(ctx, rec.VMID, rel, data)
			}
			if werr == nil {
				return helper.JSON(map[string]any{"ok": true})
			}
			if !errors.Is(werr, vmm.ErrTooLarge) {
				return nil, werr
			}
		}
		return helper.JSON(map[string]any{"ok": false, "asleep": true, "error": "Start the computer before changing its files."})
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	// File operations run through the existing serialized sandbox command path.
	args := map[string]any{"op": in.Operation, "path": target, "content": in.Content, "base64": in.Base64}
	b, _ := json.Marshal(args)
	script := `import os,json,base64,shutil
p=json.loads(base64.b64decode('` + base64.StdEncoding.EncodeToString(b) + `')); target=os.path.realpath(p['path']); root=os.path.realpath('/workspace')
if target!=root and not target.startswith(root+'/'): raise ValueError('Path escapes workspace')
op=p['op']
if op=='list': result={'items':[{'name':f,'type':'dir' if os.path.isdir(os.path.join(target,f)) else 'file','size':os.path.getsize(os.path.join(target,f))} for f in sorted(os.listdir(target)) if os.path.join(target,f)!='/workspace/.tradera/browser-profile']}
elif op=='read':
 data=open(target,'rb').read(67108865)
 if len(data)>67108864: raise ValueError('File too large')
 result={'content':data.decode('utf-8',errors='replace'),'data_base64':base64.b64encode(data).decode(),'size':len(data)}
elif op=='write':
 os.makedirs(os.path.dirname(target),exist_ok=True);data=base64.b64decode(p['base64']) if p.get('base64') else p['content'].encode();open(target,'wb').write(data);result={'ok':True}
elif op=='mkdir': os.makedirs(target,exist_ok=True);result={'ok':True}
elif op=='delete':
 if target==root: raise ValueError('Cannot delete workspace root')
 shutil.rmtree(target) if os.path.isdir(target) else os.unlink(target);result={'ok':True}
else: raise ValueError('Invalid file operation')
print(json.dumps(result))`
	if in.Operation == "preview" {
		return s.websitePreview(ctx, sp, req.Caller.ID)
	}
	output, e := s.SandboxExec(ctx, sp, "python3 -c "+shellFilePath(script))
	if e != nil {
		return nil, e
	}
	line := strings.TrimSpace(output)
	if i := strings.Index(line, "\n"); strings.HasPrefix(line, "exit=") && i >= 0 {
		if !strings.HasPrefix(line, "exit=0\n") {
			return nil, errs.InvalidArgument(line)
		}
		line = line[i+1:]
	}
	var response map[string]any
	if e = json.Unmarshal([]byte(line), &response); e != nil {
		return nil, errs.InvalidArgument("file operation failed: " + line)
	}
	return helper.JSON(response)
}
func (s *Service) websitePreview(ctx context.Context, sp, actor identity.ID) (*api.ActionResponse, error) {
	command := `cd /workspace; if test -f package.json; then if test -f package-lock.json; then npm ci >/tmp/tradera-install.log 2>&1; else npm install >/tmp/tradera-install.log 2>&1; fi; (nohup npm run dev -- --host 0.0.0.0 --port 4173 >/tmp/tradera-preview.log 2>&1 </dev/null &); elif test -f index.html; then (nohup python3 -m http.server 4173 --bind 0.0.0.0 >/tmp/tradera-preview.log 2>&1 </dev/null &); else exit 3; fi; for i in $(seq 1 30); do curl -fsS http://127.0.0.1:4173/ >/dev/null && exit 0; sleep 1; done; tail -30 /tmp/tradera-preview.log; exit 1`
	out, e := s.SandboxExec(ctx, sp, command)
	if strings.HasPrefix(out, "exit=3") {
		// Nothing to serve at the top of the files (a site in a folder of its
		// own is started by the agent that built it): say so in plain words.
		return nil, errs.NotFound("There is no website at the top of this project's files to preview. Ask the team to start it and share the link.")
	}
	if e != nil {
		return nil, e
	}
	if !strings.HasPrefix(out, "exit=0") {
		return nil, errs.New(errs.CodeUnavailable, "Preview did not become ready: "+out)
	}
	p, e := s.ProxyCreate(ctx, sp, identity.ID{}, actor, 4173, "Website preview")
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "dir": ".", "port": 4173, "url": p.GatewayPath(), "live": true})
}

// desktopScript is tradera-desktop: the one program that starts, drives and
// stops the project's desktop. It is written onto the machine on every start, so
// a machine built from an older image gets the current one too (the image bakes
// the same file for agents).
//
//go:embed desktop.sh
var desktopScript []byte

// DesktopScript is the desktop program, for the sandbox image to carry.
func DesktopScript() []byte { return desktopScript }

// desktopRun installs the desktop program on the machine and runs one of its
// commands. The output starts with exit=<code> (see SandboxExec).
func (s *Service) desktopRun(ctx context.Context, sp identity.ID, args string) (string, error) {
	return s.SandboxExec(ctx, sp, desktopInstallCommand()+" && tradera-desktop "+args)
}

// requireFundsForComputer fails when the person cannot pay for the project's
// computer (an empty wallet, or the project's budget used up).
func (s *Service) requireFundsForComputer(ctx context.Context, spaceID, payer identity.ID) error {
	if s.Bots == nil {
		return nil
	}
	botID, err := s.SandboxBotID(ctx, spaceID)
	if err != nil {
		return err
	}
	return s.Bots.EnsureFunds(billingScope(ctx, spaceID, identity.ID{}, botID, payer), payer, botID)
}

// desktopInstallCommand writes the desktop program onto the machine.
func desktopInstallCommand() string {
	return "echo " + base64.StdEncoding.EncodeToString(desktopScript) +
		" | base64 -d >/usr/local/bin/tradera-desktop && chmod +x /usr/local/bin/tradera-desktop"
}

// provideDesktopScript puts the desktop program on a machine that has just
// woken, so agents can run `tradera-desktop` even when the machine's image is
// older than the program. Best effort: a machine without it still works.
func (s *Service) provideDesktopScript(ctx context.Context, rec *bot.Bot) {
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return
	}
	if sender, ok := vm.(interface {
		Send(ctx context.Context, vmID, command string) (string, error)
	}); ok {
		_, _ = sender.Send(ctx, rec.VMID, desktopInstallCommand())
	}
}

func (s *Service) desktopInstall(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	sp, e := s.computerScope(ctx, req, true)
	if e != nil {
		return nil, e
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	// A computer costs money while it is awake: whoever opens it must be able to
	// pay (the same gate as running a command on it).
	if e := s.requireFundsForComputer(ctx, sp, req.Caller.ID); e != nil {
		return nil, e
	}
	// Starting is idempotent: a second person (or an agent) opening Computer
	// joins the running session instead of replacing it.
	output, e := s.desktopRun(ctx, sp, "start")
	if e != nil {
		return nil, e
	}
	if !strings.HasPrefix(output, "exit=0") {
		return nil, errs.New(errs.CodeUnavailable, "The desktop did not start: "+strings.TrimSpace(strings.TrimPrefix(output, "exit=1")))
	}
	password, viewer := "", ""
	for _, line := range strings.Split(output, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "DESKTOP_PASSWORD:"); ok {
			password = v
		}
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "DESKTOP_VIEWER:"); ok && desktopViewerPage(v) {
			viewer = v
		}
	}
	if password == "" {
		return nil, errs.New(errs.CodeUnavailable, "The desktop started without a password: "+output)
	}
	p, e := s.desktopProxy(ctx, sp, req.Caller.ID)
	if e != nil {
		return nil, e
	}
	gui := map[string]any{"installed": true, "url": p.GatewayPath() + "vnc.html?path=" + p.GatewayPath() + "websockify", "password": password, "web_port": 6080}
	if e = s.M.Patch(ctx, sp, jsonpatch.Patch{{Op: "set", Path: "desktop", Value: gui}}); e != nil {
		return nil, e
	}
	s.computerChanged()
	out := map[string]any{"page": p.GatewayPath()}
	for k, v := range gui {
		out[k] = v
	}
	if viewer != "" {
		// The app's own viewer: the screen alone, scaled to fit, with the
		// password in the fragment so it never reaches a server log.
		out["viewer"] = p.GatewayPath() + viewer
	}
	return helper.JSON(out)
}
func (s *Service) desktopUninstall(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	sp, e := s.computerScope(ctx, req, true)
	if e != nil {
		return nil, e
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	out, e := s.desktopRun(ctx, sp, "stop")
	if e != nil {
		return nil, e
	}
	if !strings.HasPrefix(out, "exit=0") {
		return nil, errs.New(errs.CodeUnavailable, fmt.Sprint(out))
	}
	if e = s.M.Patch(ctx, sp, jsonpatch.Patch{{Op: "set", Path: "desktop", Value: map[string]any{"installed": false}}}); e != nil {
		return nil, e
	}
	s.computerChanged()
	return helper.JSON(map[string]any{"ok": true})
}

// desktopViewerPage accepts the viewer page the desktop program names: a
// plain file name at the top of the noVNC folder.
func desktopViewerPage(name string) bool {
	if name == "" || len(name) > 64 || !strings.HasSuffix(name, ".html") {
		return false
	}
	for _, r := range name {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.') {
			return false
		}
	}
	return !strings.Contains(name, "..")
}
