package spaces

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	bots "github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// sandboxIdleTTL is how long the shared space sandbox stays alive after the
// last agent activity before it is stopped (but not deleted).
const sandboxIdleTTL = 2 * time.Minute

// A published preview uses the same idle window as the computer. An open
// desktop renews activity through keepalives; its tunnel must not reserve an
// extra thirty minutes after the panel is closed.
const sandboxPreviewTTL = sandboxIdleTTL

// defaultSandboxImage is the per-space sandbox computer (deploy/sandbox-computer):
// the shared shell and filesystem every agent of the space works on, with a
// Node.js/Python/git toolchain so agents can build and run software there.
const defaultSandboxImage = "tradera/sandbox-computer:latest"

// sandboxImage is the configured sandbox computer image (sandbox.image).
func (s *Service) sandboxImage() string {
	if s.SandboxImage != "" {
		return s.SandboxImage
	}
	return defaultSandboxImage
}

// sandboxVMType maps the configured sandbox backend onto the bot VM type: a
// standalone docker container per space ("docker", the default) or a Modal
// remote sandbox per space ("modal").
func (s *Service) sandboxVMType() bot.VMType {
	if strings.EqualFold(s.SandboxBackend, "modal") {
		return bot.VMTypeModal
	}
	return bot.VMTypeContainer
}

// sandboxState tracks one space's shared sandbox bot and its idle timer.
type sandboxState struct {
	botID        identity.ID
	lastActive   time.Time
	previewUntil time.Time
	active       int
	timer        *time.Timer
	// billedUntil is how far the computer's awake time has been charged (zero
	// while it is not known to be awake); payer is who last used it.
	billedUntil time.Time
	payer       identity.ID
}

// Bots is the bot service used to provision the sandbox VM. It is injected by
// the composition root to avoid an import cycle at the package level.
// SandboxEnsure returns (creating if needed) the shared sandbox bot for
// a space — a docker container when sandbox.backend=docker (default), a Modal
// remote sandbox when sandbox.backend=modal. It is owned by the space owner,
// runs as a member of the space and is addressed via spaces.ask — agents call
// sandbox_exec on it.
func (s *Service) SandboxEnsure(ctx context.Context, spaceID identity.ID) (*bot.Bot, error) {
	if vmm.ExecutionFrom(ctx).NoSandbox {
		return nil, errs.Permission("sandbox access is disabled for this request")
	}
	s.sandboxEnsureMu.Lock()
	defer s.sandboxEnsureMu.Unlock()
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	s.sandboxMu.Lock()
	st, ok := s.sandboxes[spaceID.String()]
	var cachedID identity.ID
	if st != nil {
		cachedID = st.botID
	}
	s.sandboxMu.Unlock()
	if ok {
		rec, err := s.Bots.GetBot(ctx, cachedID)
		if err == nil {
			return s.upgradeLegacySandbox(ctx, rec)
		}
	}
	// Look up an existing sandbox bot id recorded in the space metadata.
	if botID, ok := s.sandboxBotID(ctx, spaceID); ok {
		rec, err := s.Bots.GetBot(ctx, botID)
		if err == nil {
			s.sandboxMu.Lock()
			if cur := s.sandboxes[spaceID.String()]; cur != nil {
				cur.botID = botID // keep its work count, timer and meter
			} else {
				s.sandboxes[spaceID.String()] = &sandboxState{botID: botID}
			}
			s.sandboxMu.Unlock()
			return s.upgradeLegacySandbox(ctx, rec)
		}
	}
	if s.Bots == nil {
		return nil, errs.New(errs.CodeUnavailable, "bot service not wired for sandboxes")
	}
	name := "sbx-" + spaceID.EntityString()
	rec, err := s.Bots.CreateBot(ctx, sp.OwnerID, bots.CreateBotRequest{
		Name:      name,
		Kind:      bot.KindTool,
		VMType:    s.sandboxVMType(),
		ImageRef:  s.sandboxImage(),
		Args:      []string{"sleep", "infinity"},
		Resources: s.sandboxResourceProfile(ctx),
		// The shared sandbox is priced by the platform (Pricing → sandbox);
		// the proceeds go to the sandbox tool owner (the space owner).
	})
	if err != nil {
		return nil, err
	}
	// The sandbox joins the space as a bot member (shared per space).
	if err := s.AddBot(ctx, sp.OwnerID, spaceID, identity.ID{}, rec.AccountID); err != nil {
		return nil, err
	}
	// Record the mapping in the space metadata for restart recovery.
	if err := s.M.Patch(ctx, spaceID, jsonpatchSet("sandbox/bot_id", rec.ID.String())); err != nil {
		return nil, err
	}
	s.sandboxMu.Lock()
	st = s.sandboxes[spaceID.String()]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[spaceID.String()] = st
	}
	st.botID = rec.ID
	s.sandboxMu.Unlock()
	return rec, nil
}

// machineSettings is the part of the admin's Machine settings spaces reads: the
// size projects are sold at (settings.Machine fills every field in).
type machineSettings struct {
	CPU      float64 `json:"cpu"`
	MemoryMB int64   `json:"memory_mb"`
	DiskMB   int64   `json:"disk_mb"`
}

// sandboxResourceProfile is the size a project's computer is sold and created at:
// the admin's Machine settings, else the node's configured size, else 2 vCPU /
// 2 GB / 4 GB.
func (s *Service) sandboxResourceProfile(ctx context.Context) bot.ResourceProfile {
	profile := s.SandboxResources
	if s.K != nil {
		var m machineSettings
		if err := bridge.Invoke(ctx, s.K, "settings", "Machine", []any{ctx}, &m); err == nil {
			if m.CPU > 0 {
				profile.CPU = m.CPU
			}
			if m.MemoryMB > 0 {
				profile.Memory = m.MemoryMB
			}
			if m.DiskMB > 0 {
				profile.Disk = m.DiskMB
			}
		}
	}
	if profile.CPU <= 0 {
		profile.CPU = 2
	}
	if profile.Memory <= 0 {
		profile.Memory = 2048
	}
	if profile.Disk <= 0 {
		profile.Disk = 4096
	}
	return profile
}

// applyMachineSize brings a sleeping computer to the size the admin has set, so a
// change of the Machine settings reaches existing projects the next time they
// wake (billing follows the same size).
func (s *Service) applyMachineSize(ctx context.Context, rec *bot.Bot) *bot.Bot {
	cur, err := rec.ParseResources()
	if err != nil || cur == nil {
		return rec
	}
	target := s.sandboxResourceProfile(ctx)
	if cur.CPU == target.CPU && cur.Memory == target.Memory && cur.Disk == target.Disk {
		return rec
	}
	target.MaxRuntimeSec = cur.MaxRuntimeSec
	_ = s.Bots.EnsureVM(ctx, rec)
	updated, err := s.Bots.Resize(ctx, rec.ID, target)
	if err != nil {
		s.L.Warn("could not apply the machine size", "bot", rec.ID.String(), "error", err)
		return rec
	}
	return updated
}

// Migrate only the old platform default. Preserve explicitly resized sandboxes
// and their files; this is an in-place VM update, never delete/recreate.
func (s *Service) upgradeLegacySandbox(ctx context.Context, rec *bot.Bot) (*bot.Bot, error) {
	profile, err := rec.ParseResources()
	if err != nil {
		return nil, err
	}
	if profile.CPU == 0.5 && profile.Memory == 256 && profile.Disk == 512 && profile.MaxRuntimeSec == 0 {
		target := s.sandboxResourceProfile(ctx)
		if target != *profile {
			return s.Bots.Resize(ctx, rec.ID, target)
		}
	}
	return rec, nil
}

// sandboxBotID reads the recorded sandbox bot id from the space metadata.
func (s *Service) sandboxBotID(ctx context.Context, spaceID identity.ID) (identity.ID, bool) {
	rec, err := s.M.Get(ctx, spaceID)
	if err != nil || rec == nil {
		return identity.ID{}, false
	}
	sandbox, ok := rec.Tree["sandbox"].(map[string]any)
	if !ok {
		return identity.ID{}, false
	}
	raw, _ := sandbox["bot_id"].(string)
	id, err := identity.Parse(raw)
	if err != nil {
		return identity.ID{}, false
	}
	return id, true
}

// SandboxBotID returns the shared sandbox bot's id for a space, ensuring it
// exists first.
func (s *Service) SandboxBotID(ctx context.Context, spaceID identity.ID) (identity.ID, error) {
	rec, err := s.SandboxEnsure(ctx, spaceID)
	if err != nil {
		return identity.ID{}, err
	}
	return rec.ID, nil
}

// SandboxStart ensures the space sandbox bot is running (agent activity).
func (s *Service) SandboxStart(ctx context.Context, spaceID identity.ID) (*bot.Bot, error) {
	rec, err := s.SandboxEnsure(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	wasRunning := rec.Status == bot.StatusRunning
	if !wasRunning {
		rec = s.applyMachineSize(ctx, rec)
	}
	staleID := rec.ID
	staleOwner := rec.OwnerID
	// Always wake/probe the sandbox VM: a retained (slept) sandbox resumes
	// instantly, and one Modal already shut down (idle/lifetime expiry) is
	// detected here and recreated fresh.
	rec, err = s.Bots.Lifecycle(ctx, rec.ID, "start")
	if err != nil {
		// Lifecycle wraps the adapter's error as VMM_ERROR, so look through it.
		if !vmGone(err) {
			return nil, err
		}
		// The underlying VM is confirmed missing — recreate the sandbox fresh.
		_ = s.Bots.DeleteBot(ctx, staleOwner, staleID)
		_ = s.M.Patch(ctx, spaceID, jsonpatch.Patch{{
			Op: "remove", Path: "sandbox/bot_id",
		}})
		s.sandboxMu.Lock()
		delete(s.sandboxes, spaceID.String())
		s.sandboxMu.Unlock()
		rec, err = s.SandboxEnsure(ctx, spaceID)
		if err != nil {
			return nil, err
		}
	}
	// A freshly (re)created sandbox is provisioned but left stopped until its
	// first start; make sure it is actually running before commands run.
	if rec.Status != bot.StatusRunning {
		if rec, err = s.Bots.Lifecycle(ctx, rec.ID, "start"); err != nil {
			return nil, err
		}
	}
	s.markAwake(spaceID, rec.ID, !wasRunning)
	if !wasRunning {
		// Starting a computer costs time and money: record what asked for it.
		s.L.Info("sandbox started", "space", spaceID.String(), "for", startedFor(), "agent", vmm.ExecutionFrom(ctx).AgentID)
		s.provideDesktopScript(ctx, rec)
		// The kit is half a megabyte: written in the background, and only when
		// the machine's copy is missing or older.
		go s.provideWebkit(context.WithoutCancel(ctx), rec)
	}
	s.touch(spaceID)
	return rec, nil
}

// startedFor names what asked for the computer to start: the nearest caller
// outside the sandbox's own start and exec functions.
func startedFor() string {
	pcs := make([]uintptr, 12)
	frames := runtime.CallersFrames(pcs[:runtime.Callers(2, pcs)])
	for {
		f, more := frames.Next()
		name := f.Function[strings.LastIndex(f.Function, ".")+1:]
		if name != "SandboxStart" && name != "SandboxExec" && name != "startedFor" && !strings.HasPrefix(name, "func") {
			return name
		}
		if !more {
			return "unknown"
		}
	}
}

// vmGone reports whether an error, or any error it wraps, says the VM no longer
// exists.
func vmGone(err error) bool {
	for ; err != nil; err = errors.Unwrap(err) {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return true
		}
	}
	return false
}

// markAwake starts (or keeps) the meter on a running computer. A computer that
// has just been started is charged from now; one already running keeps the
// point its time was last charged to.
func (s *Service) markAwake(spaceID, botID identity.ID, fresh bool) {
	s.sandboxMu.Lock()
	defer s.sandboxMu.Unlock()
	st := s.sandboxes[spaceID.String()]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[spaceID.String()] = st
	}
	st.botID = botID
	if fresh || st.billedUntil.IsZero() {
		st.billedUntil = time.Now()
	}
}

// notePayer remembers who is using the computer, for charging its time.
func (s *Service) notePayer(ctx context.Context, spaceID identity.ID) {
	payer := helper.Actor(ctx)
	if id, err := identity.Parse(vmm.ExecutionFrom(ctx).ActorID); err == nil && !id.IsZero() {
		payer = id
	}
	if payer.IsZero() {
		return
	}
	s.sandboxMu.Lock()
	if st := s.sandboxes[spaceID.String()]; st != nil {
		st.payer = payer
	}
	s.sandboxMu.Unlock()
}

// takeComputeTime returns the awake time not yet charged up to [until] and who
// pays for it, and moves the meter forward. The caller holds sandboxMu.
func takeComputeTime(st *sandboxState, until time.Time) (time.Duration, identity.ID) {
	if st == nil || st.billedUntil.IsZero() || until.Sub(st.billedUntil) < time.Second {
		return 0, identity.ID{}
	}
	d := until.Sub(st.billedUntil)
	st.billedUntil = until
	return d, st.payer
}

// billComputeTime charges awake time to the person who used the computer (the
// project's owner when nobody is known). A wallet or budget that cannot cover
// it stops the computer.
func (s *Service) billComputeTime(ctx context.Context, spaceID, botID identity.ID, d time.Duration, payer identity.ID) {
	if d < time.Second || s.Bots == nil {
		return
	}
	if payer.IsZero() {
		sp, err := s.GetSpace(ctx, spaceID)
		if err != nil {
			return
		}
		payer = sp.OwnerID
	}
	err := s.Bots.BillUsage(billingScope(ctx, spaceID, identity.ID{}, botID, payer), payer, botID, int64(d.Seconds()), bots.ComputerTimeDesc)
	if err != nil {
		s.L.Warn("computer time not charged", "space", spaceID.String(), "error", err)
		if errs.CodeOf(err) == errs.CodeFinance {
			_, _ = s.Bots.Lifecycle(ctx, botID, "stop")
			s.cancelTimer(spaceID)
		}
	}
}

// settleComputeTime charges a space's computer for the time up to [until].
func (s *Service) settleComputeTime(ctx context.Context, spaceID identity.ID, until time.Time) {
	s.sandboxMu.Lock()
	st := s.sandboxes[spaceID.String()]
	botID := identity.ID{}
	if st != nil {
		botID = st.botID
	}
	d, payer := takeComputeTime(st, until)
	s.sandboxMu.Unlock()
	if !botID.IsZero() {
		s.billComputeTime(ctx, spaceID, botID, d, payer)
	}
}

// SandboxStop stops the space sandbox bot (idle agents) without deleting it.
func (s *Service) SandboxStop(ctx context.Context, spaceID identity.ID) (*bot.Bot, error) {
	gate := s.sandboxGate(spaceID)
	if len(gate) > 0 {
		return nil, errs.Conflict("sandbox has active operations")
	}
	select {
	case gate <- struct{}{}:
	default:
		return nil, errs.Conflict("sandbox has active operations")
	}
	defer func() { <-gate }()
	s.sandboxMu.Lock()
	if st := s.sandboxes[spaceID.String()]; st != nil && st.active > 0 {
		s.sandboxMu.Unlock()
		return nil, errs.Conflict("sandbox has active operations")
	}
	s.sandboxMu.Unlock()
	rec, err := s.SandboxEnsure(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	if rec.Status == bot.StatusRunning {
		rec, err = s.Bots.Lifecycle(ctx, rec.ID, "stop")
		if err != nil {
			return nil, err
		}
	}
	s.cancelTimer(spaceID)
	s.settleComputeTime(ctx, spaceID, time.Now())
	s.sandboxMu.Lock()
	if st := s.sandboxes[spaceID.String()]; st != nil {
		st.billedUntil = time.Time{}
	}
	s.sandboxMu.Unlock()
	return rec, nil
}

// SandboxStatus reports the shared sandbox bot for a space.
func (s *Service) SandboxStatus(ctx context.Context, spaceID identity.ID) (map[string]any, error) {
	id, ok := s.sandboxBotID(ctx, spaceID)
	if !ok {
		return map[string]any{"space_id": spaceID.String(), "status": "unprovisioned", "vm_type": s.sandboxVMType()}, nil
	}
	rec, err := s.Bots.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	rec = s.reconcileSandbox(ctx, spaceID, rec)

	s.sandboxMu.Lock()
	st := s.sandboxes[spaceID.String()]
	active := st != nil && st.timer != nil
	s.sandboxMu.Unlock()
	return map[string]any{
		"space_id":  spaceID.String(),
		"bot_id":    rec.ID.String(),
		"vm_id":     rec.VMID,
		"name":      rec.Name,
		"vm_type":   rec.VMType,
		"status":    rec.Status,
		"idle_stop": active,
	}, nil
}

// reconcileSandbox makes the stored status of a computer match reality. A
// computer marked running whose provider says it is gone (it ended on its own, or
// was ended from the provider's console) is recorded as stopped, and the time it
// ran is charged.
func (s *Service) reconcileSandbox(ctx context.Context, spaceID identity.ID, rec *bot.Bot) *bot.Bot {
	if rec.Status != bot.StatusRunning || rec.VMID == "" {
		return rec
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	probe, ok := vm.(interface {
		Alive(ctx context.Context, id string) bool
	})
	if !ok || probe.Alive(ctx, rec.VMID) {
		return rec
	}
	stopped, err := s.Bots.Lifecycle(ctx, rec.ID, "stop")
	if err != nil {
		return rec
	}
	s.cancelTimer(spaceID)
	s.settleComputeTime(ctx, spaceID, time.Now())
	s.sandboxMu.Lock()
	if st := s.sandboxes[spaceID.String()]; st != nil {
		st.billedUntil = time.Time{}
	}
	s.sandboxMu.Unlock()
	return stopped
}

// SandboxExec runs a shell command inside the shared space sandbox and returns
// its output. It starts the sandbox on demand and schedules the idle stop.
func (s *Service) SandboxExec(ctx context.Context, spaceID identity.ID, command string) (string, error) {
	gate := s.sandboxGate(spaceID)
	// One command at a time per computer: time spent here is waiting behind another.
	endWait := vmm.Trace(ctx, "sandbox.queue", "waiting for the computer's turn")
	select {
	case gate <- struct{}{}:
		endWait()
	case <-ctx.Done():
		endWait()
		return "", ctx.Err()
	}
	defer func() { <-gate }()
	s.sandboxMu.Lock()
	key := spaceID.String()
	st := s.sandboxes[key]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[key] = st
	}
	st.active++
	s.sandboxMu.Unlock()
	defer func() {
		s.sandboxMu.Lock()
		if current := s.sandboxes[key]; current != nil && current.active > 0 {
			current.active--
		}
		s.sandboxMu.Unlock()
		s.touch(spaceID)
	}()
	// Starting (or waking) the computer: the slow part of a first command.
	endStart := vmm.Trace(ctx, "sandbox.start", "create or wake the computer")
	rec, err := s.SandboxStart(ctx, spaceID)
	endStart()
	if err != nil {
		return "", err
	}
	s.notePayer(ctx, spaceID)
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return "", errs.New(errs.CodeUnavailable, "no VMM adapter for "+string(rec.VMType))
	}
	execVM, ok := vm.(interface {
		Send(ctx context.Context, vmID, command string) (string, error)
	})
	if !ok || rec.VMID == "" {
		return "", errs.New(errs.CodeUnavailable, "sandbox VM does not support exec")
	}
	if dir := vmm.WorkingDirectory(vmm.ExecutionFrom(ctx).RunID); dir != "" {
		command = "mkdir -p " + dir + " && cd " + dir + " && (" + command + "\n)"
	}
	endExec := vmm.Trace(ctx, "sandbox.exec", clipTrace(command, 80))
	out, err := execVM.Send(ctx, rec.VMID, command)
	endExec()
	if err != nil {
		return out, err
	}
	s.touch(spaceID)
	// Universal bot asks and scheduled routines use this path as well as agent
	// tools. A successful transport must not turn a failed command into success.
	return out, sandboxCommandError(out)
}

// touch resets the idle timer so the sandbox stays up while agents work.
func (s *Service) touch(spaceID identity.ID) {
	key := spaceID.String()
	s.sandboxMu.Lock()
	defer s.sandboxMu.Unlock()
	st := s.sandboxes[key]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[key] = st
	}
	st.lastActive = time.Now().UTC()
	if st.timer != nil {
		st.timer.Stop()
	}
	if st.botID.IsZero() {
		if id, ok := s.sandboxBotID(context.Background(), spaceID); ok {
			st.botID = id
		}
	}
	if st.botID.IsZero() {
		return
	}
	botID := st.botID
	st.timer = time.AfterFunc(sandboxIdleDelay(st, time.Now()), func() { s.idleStop(key, botID) })
}

func sandboxIdleDelay(st *sandboxState, now time.Time) time.Duration {
	deadline := st.lastActive.Add(sandboxIdleTTL)
	if st.previewUntil.After(deadline) {
		deadline = st.previewUntil
	}
	return max(time.Duration(0), deadline.Sub(now))
}

// holdPreview renews a finite lease rather than disabling idle reclamation.
func (s *Service) holdPreview(spaceID identity.ID) {
	s.sandboxMu.Lock()
	key := spaceID.String()
	st := s.sandboxes[key]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[key] = st
	}
	st.previewUntil = time.Now().UTC().Add(sandboxPreviewTTL)
	s.sandboxMu.Unlock()
	s.touch(spaceID)
}

// idleStop stops a space sandbox after the idle window elapses, then charges
// the time it was awake.
func (s *Service) idleStop(key string, botID identity.ID) {
	var charge func()
	defer func() {
		if charge != nil {
			charge()
		}
	}()
	s.sandboxMu.Lock()
	defer s.sandboxMu.Unlock()
	st := s.sandboxes[key]
	if st == nil || st.botID != botID {
		return
	}
	if st.active > 0 {
		// Work is running; its release touches the computer again and re-arms the timer.
		st.timer = nil
		return
	}
	// Not idle for long enough yet (the timer can fire a moment early, or a
	// preview extended the lease): look again when it will be, never give up.
	if delay := sandboxIdleDelay(st, time.Now()); delay > 0 {
		st.timer = time.AfterFunc(delay+50*time.Millisecond, func() { s.idleStop(key, botID) })
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rec, err := s.Bots.GetBot(ctx, botID)
	if err == nil && rec.Status == bot.StatusRunning {
		_, err = s.Bots.Lifecycle(ctx, botID, "stop")
	}
	if err != nil {
		s.L.Warn("sandbox idle stop failed", "error", err)
		st.timer = time.AfterFunc(5*time.Second, func() { s.idleStop(key, botID) })
		return
	}
	st.timer = nil
	// The awake time ends now; it is charged once the lock is released.
	d, payer := takeComputeTime(st, time.Now())
	st.billedUntil = time.Time{}
	if spaceID, perr := identity.Parse(key); perr == nil && d > 0 {
		charge = func() {
			bctx, bcancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer bcancel()
			s.billComputeTime(bctx, spaceID, botID, d, payer)
		}
	}
}

// reapIdleSandboxes keeps every running computer honest, every few seconds:
//
//   - it charges the time each one has been awake (a minute at a time), so a
//     computer left on, or watched, is paid for as it runs and a wallet or
//     budget that runs out stops it;
//   - it stops running computers that no idle timer is watching. Timers live in
//     memory, so after a node restart a computer that was awake would otherwise
//     stay awake (and bill) forever.
func (s *Service) reapIdleSandboxes(ctx context.Context) {
	if s.Bots == nil {
		return
	}
	var rows []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": string(bot.KindTool), "status": string(bot.StatusRunning)}}, &rows); err != nil {
		return
	}
	var running []bot.Bot
	for i := range rows {
		if rows[i].IsSandbox() {
			running = append(running, rows[i])
		}
	}
	if len(running) == 0 {
		s.sandboxMu.Lock()
		s.idleSeen = nil
		s.sandboxMu.Unlock()
		return
	}
	// Computers this process knows nothing about (it restarted since they woke):
	// find their project by the computer's name, and start metering them now.
	spaceByName := map[string]identity.ID{}
	s.sandboxMu.Lock()
	known := map[identity.ID]string{}
	for key, st := range s.sandboxes {
		if !st.botID.IsZero() {
			known[st.botID] = key
		}
	}
	s.sandboxMu.Unlock()
	for i := range running {
		if _, ok := known[running[i].ID]; ok {
			continue
		}
		if len(spaceByName) == 0 {
			var all []space.Space
			if err := s.R.List(ctx, "spaces", database.Filter{}, &all); err == nil {
				for _, sp := range all {
					spaceByName["sbx-"+sp.ID.EntityString()] = sp.ID
				}
			}
		}
		if spaceID, ok := spaceByName[running[i].Name]; ok {
			s.markAwake(spaceID, running[i].ID, true)
			known[running[i].ID] = spaceID.String()
		}
	}

	now := time.Now()
	type due struct {
		space, bot identity.ID
		d          time.Duration
		payer      identity.ID
	}
	var bill []due
	var stop []due
	s.sandboxMu.Lock()
	if s.idleSeen == nil {
		s.idleSeen = map[identity.ID]time.Time{}
	}
	live := map[identity.ID]bool{}
	for i := range running {
		key, ok := known[running[i].ID]
		st := s.sandboxes[key]
		if !ok || st == nil {
			continue
		}
		spaceID, _ := identity.Parse(key)
		if st.billedUntil.IsZero() {
			st.billedUntil = now
		}
		if now.Sub(st.billedUntil) >= time.Minute {
			d, payer := takeComputeTime(st, now)
			bill = append(bill, due{space: spaceID, bot: running[i].ID, d: d, payer: payer})
		}
		if st.active > 0 {
			continue
		}
		// A computer whose idle deadline passed a while ago is stuck whatever its
		// timer says (a timer that fired early and was not re-armed leaves a stale one).
		deadline := st.lastActive.Add(sandboxIdleTTL)
		if st.previewUntil.After(deadline) {
			deadline = st.previewUntil
		}
		if !st.lastActive.IsZero() && !now.Before(deadline) {
			stop = append(stop, due{space: spaceID, bot: running[i].ID})
			continue
		}
		if st.timer != nil && !st.lastActive.IsZero() {
			continue // a live timer is watching it
		}
		live[running[i].ID] = true
		first, seen := s.idleSeen[running[i].ID]
		if !seen {
			s.idleSeen[running[i].ID] = now
		} else if now.Sub(first) >= sandboxIdleTTL {
			stop = append(stop, due{space: spaceID, bot: running[i].ID})
		}
	}
	for id := range s.idleSeen {
		if !live[id] {
			delete(s.idleSeen, id)
		}
	}
	s.sandboxMu.Unlock()
	for _, b := range bill {
		s.billComputeTime(ctx, b.space, b.bot, b.d, b.payer)
	}
	for _, st := range stop {
		// A desktop heartbeat or command may have arrived since the scan.
		// Recheck activity under the same lock as the timer before stopping.
		s.idleStop(st.space.String(), st.bot)
	}
}

// SandboxDestroy permanently terminates a space's shared sandbox (the Modal
// instance is deleted). This is only called when the space itself is deleted —
// idle stops just sleep the sandbox and keep the instance retained.
func (s *Service) SandboxDestroy(ctx context.Context, spaceID identity.ID) error {
	botID, ok := s.sandboxBotID(ctx, spaceID)
	if !ok {
		return nil
	}
	// Charge the time the computer was awake up to now before it goes away.
	s.settleComputeTime(ctx, spaceID, time.Now())
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil {
		return nil
	}
	// DeleteBot -> DeleteVM terminates the underlying Modal sandbox.
	if err := s.Bots.DeleteBot(ctx, rec.OwnerID, botID); err != nil {
		s.L.Warn("destroy sandbox bot", "space", spaceID.String(), "bot", botID.String(), "error", err)
	}
	// The project's files outlive any one computer, but not the project.
	if ws, ok := s.K.VMMFor(vmm.TypeModal).(vmm.VolumeDeleter); ok {
		if err := ws.DeleteWorkspaceVolume(ctx, rec.Name); err != nil {
			s.L.Warn("destroy sandbox workspace", "space", spaceID.String(), "machine", rec.Name, "error", err)
		}
	}
	s.cancelTimer(spaceID)
	s.sandboxMu.Lock()
	delete(s.sandboxes, spaceID.String())
	s.sandboxMu.Unlock()
	return nil
}

// cancelTimer cancels a space's pending idle stop.
func (s *Service) cancelTimer(spaceID identity.ID) {
	s.sandboxMu.Lock()
	defer s.sandboxMu.Unlock()
	if st, ok := s.sandboxes[spaceID.String()]; ok && st.timer != nil {
		st.timer.Stop()
		st.timer = nil
	}
}

// StopAllSandboxes stops every shared sandbox (called on node shutdown).
func (s *Service) StopAllSandboxes(ctx context.Context) {
	s.sandboxMu.Lock()
	ids := make([]identity.ID, 0, len(s.sandboxes))
	for _, st := range s.sandboxes {
		if st.timer != nil {
			st.timer.Stop()
			st.timer = nil
		}
		if !st.botID.IsZero() {
			ids = append(ids, st.botID)
		}
	}
	s.sandboxMu.Unlock()
	for _, id := range ids {
		rec, err := s.Bots.GetBot(ctx, id)
		if err == nil && rec.Status == bot.StatusRunning {
			_, _ = s.Bots.Lifecycle(ctx, id, "stop")
		}
	}
	// Charge the time they were awake up to shutdown.
	s.sandboxMu.Lock()
	spaces := make([]string, 0, len(s.sandboxes))
	for key := range s.sandboxes {
		spaces = append(spaces, key)
	}
	s.sandboxMu.Unlock()
	for _, key := range spaces {
		if spaceID, err := identity.Parse(key); err == nil {
			s.settleComputeTime(ctx, spaceID, time.Now())
		}
	}
}

func jsonpatchSet(path, value string) jsonpatch.Patch {
	return jsonpatch.Patch{{Op: "set", Path: path, Value: value}}
}

// sandboxConcurrency bounds commands running at once in one space's sandbox.
// Every agent of a space shares that machine, so a swarm's commands run side
// by side instead of queueing behind each other.
const sandboxConcurrency = 6

func (s *Service) sandboxGate(spaceID identity.ID) chan struct{} {
	gate, _ := s.sandboxOperations.LoadOrStore(spaceID.String(), make(chan struct{}, sandboxConcurrency))
	return gate.(chan struct{})
}

// clipTrace is a command shortened to a line for the turn's trace.
func clipTrace(text string, n int) string {
	text = strings.Join(strings.Fields(text), " ")
	if r := []rune(text); len(r) > n {
		return string(r[:n]) + "…"
	}
	return text
}
