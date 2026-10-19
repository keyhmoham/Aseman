package developer

import (
	"context"
	"encoding/base64"
	"fmt"
	"math"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// DefaultImage is the standard computer: the machine the app's own project
// computers run.
const DefaultImage = "tradera/sandbox-computer:latest"

const (
	// IdleStop is how long a computer may sit without a command before it is stopped.
	IdleStop = 2 * time.Minute
	// MaxComputers is how many computers one organization may have.
	MaxComputers = 10
	// maxCommand is the longest command, in bytes.
	maxCommand = 64 << 10

	computerRunning = "running"
	computerStopped = "stopped"
)

// MachineSettings is the part of the admin's Machine settings the developer
// computers follow: the same sizes and limits as a project's computer.
type MachineSettings struct {
	CPU               float64 `json:"cpu"`
	MemoryMB          int64   `json:"memory_mb"`
	DiskMB            int64   `json:"disk_mb"`
	MaxCPU            float64 `json:"max_cpu"`
	MaxMemoryMB       int64   `json:"max_memory_mb"`
	MaxLifetimeMin    int64   `json:"max_lifetime_min"`
	CommandTimeoutSec int64   `json:"command_timeout_sec"`
}

// ComputerRate is what a running minute costs, in ledger units: the platform's
// sandbox price (Admin → Settings → Pricing).
type ComputerRate struct {
	PerMinute      int64 `json:"per_minute"`
	CPUPerMin      int64 `json:"cpu_per_min"`
	MemoryPerGBMin int64 `json:"memory_per_gb_min"`
	DiskPerGBMin   int64 `json:"disk_per_gb_min"`
}

// Infra is what computers need of the rest of the node.
type Infra interface {
	Machine(ctx context.Context) (MachineSettings, error)
	Rate(ctx context.Context) (ComputerRate, error)
	// StoragePrice is what a GB kept in Storage costs for a month (ledger units).
	StoragePrice(ctx context.Context) (int64, error)
	// NodeOwner is paid for the machine time and the storage.
	NodeOwner(ctx context.Context) identity.ID
}

// Range is a bound a size moves in.
type Range struct {
	Min     float64 `json:"min"`
	Max     float64 `json:"max"`
	Step    float64 `json:"step"`
	Default float64 `json:"default"`
}

// ImageView is an image a computer can start from.
type ImageView struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Includes    []string `json:"includes"`
	Builtin     bool     `json:"builtin"`
}

// ComputerPricing is what a minute costs.
type ComputerPricing struct {
	PerMinute      int64 `json:"perMinute"`
	CPUPerMin      int64 `json:"cpuPerMin"`
	MemoryPerGBMin int64 `json:"memoryPerGbMin"`
	DiskPerGBMin   int64 `json:"diskPerGbMin"`
	DiskMB         int64 `json:"diskMb"`
}

// ComputerOptions are the real limits of a computer, so a client never has to guess.
type ComputerOptions struct {
	CPU      Range `json:"cpu"`
	MemoryMB Range `json:"memoryMb"`
	// Burst is how far a busy computer may go: the platform's ceiling, which
	// is not chosen per computer.
	Burst struct {
		CPU      float64 `json:"cpu"`
		MemoryMB int64   `json:"memoryMb"`
	} `json:"burst"`
	Images            []ImageView     `json:"images"`
	IdleStopMin       int64           `json:"idleStopMin"`
	MaxLifetimeMin    int64           `json:"maxLifetimeMin"`
	CommandTimeoutSec int64           `json:"commandTimeoutSec"`
	Pricing           ComputerPricing `json:"pricing"`
}

// ComputerSpec is the size of a computer.
type ComputerSpec struct {
	CPU      float64 `json:"cpu"`
	MemoryMB int64   `json:"memoryMb"`
}

// ComputerView is a computer as the console shows it.
type ComputerView struct {
	ID           string       `json:"id"`
	Name         string       `json:"name"`
	Status       string       `json:"status"`
	Image        string       `json:"image"`
	Spec         ComputerSpec `json:"spec"`
	CreatedAt    string       `json:"createdAt"`
	LastActiveAt string       `json:"lastActiveAt,omitempty"`
	Minutes      float64      `json:"minutes"`
}

// ComputerInput is what a computer is made from.
type ComputerInput struct {
	Name  string       `json:"name"`
	Image string       `json:"image"`
	Spec  ComputerSpec `json:"spec"`
}

// ExecResult is what a command did. Standard error is part of Output.
type ExecResult struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
	Ms       int64  `json:"ms"`
}

const stepCPU, stepMemory = 0.25, 256

var imageRX = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._:/@-]{0,199}$`)

func (s *Service) imageList() []ImageView {
	id := s.SandboxImage
	if id == "" {
		id = DefaultImage
	}
	return []ImageView{{
		ID: id, Name: "Tradera standard computer", Builtin: true,
		Description: "The same machine the project computers run: Debian with the tools agents and developers reach for, and a desktop with a browser.",
		Includes:    []string{"Debian 12 (bookworm)", "Node.js 22 and Python 3 with pip and venv", "git, curl, wget, jq, ripgrep, fd, tree, sqlite3", "build-essential (gcc, make)", "Chromium and a remote desktop (Xvfb, VNC, noVNC)"},
	}}
}

// ComputerOptions reads the limits from the node's settings.
func (s *Service) ComputerOptions(ctx context.Context) (*ComputerOptions, error) {
	m, err := s.Infra.Machine(ctx)
	if err != nil {
		return nil, err
	}
	rate, err := s.Infra.Rate(ctx)
	if err != nil {
		return nil, err
	}
	maxCPU, maxMem := math.Max(m.MaxCPU, 0.25), float64(max(m.MaxMemoryMB, 512))
	o := &ComputerOptions{
		CPU:         Range{Min: 0.25, Max: maxCPU, Step: stepCPU, Default: math.Min(maxCPU, math.Max(0.25, m.CPU))},
		MemoryMB:    Range{Min: 512, Max: maxMem, Step: stepMemory, Default: math.Min(maxMem, math.Max(512, float64(m.MemoryMB)))},
		Images:      s.imageList(),
		IdleStopMin: int64(IdleStop / time.Minute), MaxLifetimeMin: m.MaxLifetimeMin, CommandTimeoutSec: m.CommandTimeoutSec,
		Pricing: ComputerPricing{PerMinute: rate.PerMinute, CPUPerMin: rate.CPUPerMin, MemoryPerGBMin: rate.MemoryPerGBMin, DiskPerGBMin: rate.DiskPerGBMin, DiskMB: m.DiskMB},
	}
	o.Burst.CPU, o.Burst.MemoryMB = m.MaxCPU, m.MaxMemoryMB
	return o, nil
}

func snap(v, step float64) float64 { return math.Round(v/step) * step }

// perMinute is what a running minute of a computer costs (ledger units).
func perMinute(c models.Computer, r ComputerRate) float64 {
	return float64(r.PerMinute) + c.CPU*float64(r.CPUPerMin) + float64(c.MemoryMB)/1024*float64(r.MemoryPerGBMin) + float64(c.DiskMB)/1024*float64(r.DiskPerGBMin)
}

func (s *Service) vm(kind string) (vmm.VMM, error) {
	v := s.VMs(vmm.Type(kind))
	if v == nil {
		return nil, errs.New(errs.CodeUnavailable, "No computer provider is running on this node.")
	}
	return v, nil
}

func vmSpec(c models.Computer) vmm.VMSpec {
	return vmm.VMSpec{Name: c.VMName, Type: vmm.Type(c.VMType), ImageRef: c.Image, Args: []string{"sleep", "infinity"},
		Resources: vmm.ResourceSpec{CPU: c.CPU, MemoryMB: c.MemoryMB, DiskMB: c.DiskMB},
		Labels:    map[string]string{"tradera.bot_id": c.ID.String()}}
}

// adopt tells the provider what a machine was made from, so one it lost track
// of (a restart) can be brought back.
func adopt(v vmm.VMM, c models.Computer) {
	if a, ok := v.(interface {
		Adopt(id string, spec vmm.VMSpec)
	}); ok {
		a.Adopt(c.VMID, vmSpec(c))
	}
}

func (s *Service) computerView(c models.Computer) ComputerView {
	seconds := c.Seconds
	if !c.RunStartedAt.IsZero() {
		seconds += int64(s.now().Sub(c.RunStartedAt).Seconds())
	}
	v := ComputerView{ID: c.ID.String(), Name: c.Name, Status: c.Status, Image: c.Image, Spec: ComputerSpec{CPU: c.CPU, MemoryMB: c.MemoryMB},
		CreatedAt: stamp(c.CreatedAt), LastActiveAt: stamp(c.LastActiveAt), Minutes: math.Round(float64(seconds)/60*10) / 10}
	return v
}

func (s *Service) loadComputer(ctx context.Context, org identity.ID, id string) (*models.Computer, error) {
	cid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.NotFound("computer")
	}
	var c models.Computer
	if err := s.R.Get(ctx, "dev_computers", cid, &c); err != nil || c.OrgID != org {
		return nil, errs.NotFound("computer")
	}
	return &c, nil
}

// Computers lists an organization's computers, newest first.
func (s *Service) Computers(ctx context.Context, org identity.ID) ([]ComputerView, error) {
	var list []models.Computer
	if err := s.R.List(ctx, "dev_computers", database.Filter{Equal: map[string]any{"org_id": org.String()}, OrderBy: "created_at"}, &list); err != nil {
		return nil, err
	}
	out := make([]ComputerView, 0, len(list))
	for _, c := range list {
		out = append(out, s.computerView(c))
	}
	return out, nil
}

// Computer is one computer.
func (s *Service) Computer(ctx context.Context, org identity.ID, id string) (*ComputerView, error) {
	c, err := s.loadComputer(ctx, org, id)
	if err != nil {
		return nil, err
	}
	v := s.computerView(*c)
	return &v, nil
}

func (s *Service) fundsFor(ctx context.Context, org identity.ID, c models.Computer) error {
	rate, err := s.Infra.Rate(ctx)
	if err != nil {
		return err
	}
	need := int64(math.Ceil(perMinute(c, rate)))
	if err := s.Fin.EnsureFunds(ctx, org, max(need, minFunds)); err != nil {
		return errs.New(errs.CodeFinance, "This organization's balance is too low to run a computer. Add funds under Billing in the console.")
	}
	return nil
}

// CreateComputer makes a computer and starts it. The size is checked against
// the node's limits, which the options endpoint reports.
func (s *Service) CreateComputer(ctx context.Context, org, by identity.ID, in ComputerInput) (*ComputerView, error) {
	opts, err := s.ComputerOptions(ctx)
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(in.Name)
	if len([]rune(name)) > 60 {
		return nil, errs.InvalidArgument("A computer's name can be up to 60 characters.")
	}
	if in.Spec.CPU == 0 {
		in.Spec.CPU = opts.CPU.Default
	}
	if in.Spec.MemoryMB == 0 {
		in.Spec.MemoryMB = int64(opts.MemoryMB.Default)
	}
	cpu, mem := snap(in.Spec.CPU, stepCPU), snap(float64(in.Spec.MemoryMB), stepMemory)
	if cpu < opts.CPU.Min || cpu > opts.CPU.Max {
		return nil, errs.InvalidArgument(fmt.Sprintf("cpu must be between %g and %g.", opts.CPU.Min, opts.CPU.Max))
	}
	if mem < opts.MemoryMB.Min || mem > opts.MemoryMB.Max {
		return nil, errs.InvalidArgument(fmt.Sprintf("memory_mb must be between %g and %g.", opts.MemoryMB.Min, opts.MemoryMB.Max))
	}
	image := strings.TrimSpace(in.Image)
	if image == "" {
		image = opts.Images[0].ID
	}
	if !imageRX.MatchString(image) {
		return nil, errs.InvalidArgument("image must be a container image reference, such as tradera/sandbox-computer:latest.")
	}
	kind := s.SandboxType()
	v, err := s.vm(kind)
	if err != nil {
		return nil, err
	}
	s.compMu.Lock()
	defer s.compMu.Unlock()
	if n, err := s.R.Count(ctx, "dev_computers", database.Filter{Equal: map[string]any{"org_id": org.String()}}); err == nil && n >= MaxComputers {
		return nil, errs.InvalidArgument(fmt.Sprintf("An organization can have up to %d computers. Delete one first.", MaxComputers))
	}
	id, err := s.newID()
	if err != nil {
		return nil, err
	}
	if name == "" {
		name = "computer-" + id.EntityString()[10:]
	}
	now := s.now()
	c := models.Computer{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OrgID: org, Name: name, Image: image, CPU: cpu, MemoryMB: int64(mem),
		DiskMB: max(opts.Pricing.DiskMB, 0), Status: computerStopped, VMName: "sbx-dev-" + id.EntityString(), VMType: kind, CreatedBy: by}
	if err := s.fundsFor(ctx, org, c); err != nil {
		return nil, err
	}
	vm, err := v.CreateVM(ctx, vmSpec(c))
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "The computer could not be created")
	}
	c.VMID = vm.ID
	if err := v.StartVM(ctx, c.VMID); err != nil {
		_ = v.DeleteVM(context.WithoutCancel(ctx), c.VMID)
		return nil, errs.Wrap(errs.CodeUnavailable, err, "The computer could not be started")
	}
	c.Status, c.RunStartedAt, c.LastActiveAt = computerRunning, now, now
	if err := s.R.CreateID(ctx, "dev_computers", id, &c); err != nil {
		_ = v.DeleteVM(context.WithoutCancel(ctx), c.VMID)
		return nil, err
	}
	view := s.computerView(c)
	return &view, nil
}

// SetComputerStatus starts or stops a computer.
func (s *Service) SetComputerStatus(ctx context.Context, org identity.ID, id, status string) (*ComputerView, error) {
	if status != computerRunning && status != computerStopped {
		return nil, errs.InvalidArgument("status must be running or stopped.")
	}
	s.compMu.Lock()
	defer s.compMu.Unlock()
	c, err := s.loadComputer(ctx, org, id)
	if err != nil {
		return nil, err
	}
	if c.Status == status {
		v := s.computerView(*c)
		return &v, nil
	}
	if status == computerRunning {
		err = s.startLocked(ctx, c)
	} else {
		err = s.stopLocked(ctx, c)
	}
	if err != nil {
		return nil, err
	}
	v := s.computerView(*c)
	return &v, nil
}

func (s *Service) startLocked(ctx context.Context, c *models.Computer) error {
	if err := s.fundsFor(ctx, c.OrgID, *c); err != nil {
		return err
	}
	v, err := s.vm(c.VMType)
	if err != nil {
		return err
	}
	adopt(v, *c)
	if err := v.StartVM(ctx, c.VMID); err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "The computer could not be started")
	}
	now := s.now()
	c.Status, c.RunStartedAt, c.RunBilled, c.LastActiveAt, c.UpdatedAt = computerRunning, now, 0, now, now
	return s.R.Update(ctx, "dev_computers", c.ID, c)
}

// billRun charges a run's time so far: whole units already earned, or, at the
// end of the run, rounded up.
func (s *Service) billRun(ctx context.Context, c *models.Computer, final bool) error {
	if c.RunStartedAt.IsZero() {
		return nil
	}
	rate, err := s.Infra.Rate(ctx)
	if err != nil {
		return err
	}
	owed := s.now().Sub(c.RunStartedAt).Seconds() * perMinute(*c, rate) / 60
	due := int64(math.Floor(owed + 1e-9))
	if final {
		due = int64(math.Ceil(owed - 1e-9))
	}
	due -= c.RunBilled
	if due <= 0 {
		return nil
	}
	desc := "developer API computer " + c.Name
	lines := []wallet.ChargeLine{{Amount: due, Payees: []identity.ID{s.Infra.NodeOwner(ctx)}, Type: wallet.EntryPayNode, Category: wallet.CategoryCompute, Desc: desc}}
	if err := s.Fin.ChargeLines(ctx, c.OrgID, desc, lines); err != nil {
		return err
	}
	c.RunBilled += due
	return nil
}

// stopLocked ends a run: it charges what is owed, stops the machine and keeps its files.
func (s *Service) stopLocked(ctx context.Context, c *models.Computer) error {
	billErr := s.billRun(ctx, c, true)
	v, err := s.vm(c.VMType)
	if err != nil {
		return err
	}
	adopt(v, *c)
	if err := v.StopVM(ctx, c.VMID); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return errs.Wrap(errs.CodeUnavailable, err, "The computer could not be stopped")
	}
	if !c.RunStartedAt.IsZero() {
		c.Seconds += int64(s.now().Sub(c.RunStartedAt).Seconds())
	}
	c.Status, c.RunStartedAt, c.RunBilled, c.UpdatedAt = computerStopped, time.Time{}, 0, s.now()
	if err := s.R.Update(ctx, "dev_computers", c.ID, c); err != nil {
		return err
	}
	if billErr != nil {
		s.L.Warn("developer: a computer's last minutes could not be billed", "computer", c.ID.String(), "error", billErr)
	}
	return nil
}

// DeleteComputer stops a computer and deletes it with its files.
func (s *Service) DeleteComputer(ctx context.Context, org identity.ID, id string) error {
	s.compMu.Lock()
	defer s.compMu.Unlock()
	c, err := s.loadComputer(ctx, org, id)
	if err != nil {
		return err
	}
	if c.Status == computerRunning {
		_ = s.billRun(ctx, c, true)
	}
	if v, err := s.vm(c.VMType); err == nil {
		adopt(v, *c)
		if err := v.DeleteVM(ctx, c.VMID); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
			return errs.Wrap(errs.CodeUnavailable, err, "The computer could not be deleted")
		}
		if vd, ok := v.(vmm.VolumeDeleter); ok {
			if err := vd.DeleteWorkspaceVolume(ctx, c.VMName); err != nil {
				s.L.Warn("developer: a computer's volume was not deleted", "computer", c.ID.String(), "error", err)
			}
		}
	}
	return s.R.Delete(ctx, "dev_computers", c.ID)
}

// Exec runs a shell command on a running computer, from /workspace.
func (s *Service) Exec(ctx context.Context, org identity.ID, id, command string, timeoutSec int64) (*ExecResult, error) {
	if strings.TrimSpace(command) == "" {
		return nil, errs.InvalidArgument("command is required.")
	}
	if len(command) > maxCommand {
		return nil, errs.InvalidArgument("The command is too long: keep it under 64 KB, or upload a script and run that.")
	}
	c, err := s.loadComputer(ctx, org, id)
	if err != nil {
		return nil, err
	}
	if c.Status != computerRunning {
		return nil, errs.Conflict("The computer is stopped. Start it first.")
	}
	m, err := s.Infra.Machine(ctx)
	if err != nil {
		return nil, err
	}
	limit := time.Duration(m.CommandTimeoutSec) * time.Second
	if timeoutSec > 0 && time.Duration(timeoutSec)*time.Second < limit {
		limit = time.Duration(timeoutSec) * time.Second
	}
	v, err := s.vm(c.VMType)
	if err != nil {
		return nil, err
	}
	sender, ok := v.(interface {
		Send(ctx context.Context, vmID, command string) (string, error)
	})
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "This node's computer provider cannot run commands.")
	}
	adopt(v, *c)
	s.activity(c.ID, 1)
	defer s.activity(c.ID, -1)
	s.touchComputer(ctx, c.ID)
	started := s.now()
	runCtx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	out, err := sender.Send(runCtx, c.VMID, "cd /workspace 2>/dev/null; "+command)
	s.touchComputer(context.WithoutCancel(ctx), c.ID)
	res := &ExecResult{Ms: s.now().Sub(started).Milliseconds()}
	if header, rest, found := strings.Cut(out, "\n"); found && strings.HasPrefix(header, "exit=") {
		res.ExitCode, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(header, "exit=")))
		res.Stdout = rest
	} else {
		res.Stdout = out
	}
	if err != nil {
		if runCtx.Err() != nil {
			return nil, errs.New(errs.CodeUnavailable, "The command took longer than "+limit.String()+" and was stopped.")
		}
		// A command that exits non-zero is a result; only a failure to run it is an error.
		if errs.CodeOf(err) == vmm.CodeToolExecutionFailed {
			return res, nil
		}
		return nil, errs.Wrap(errs.CodeUnavailable, err, "The command could not be run")
	}
	return res, nil
}

func (s *Service) activity(id identity.ID, delta int) {
	s.compActMu.Lock()
	defer s.compActMu.Unlock()
	s.compActive[id.String()] += delta
	if s.compActive[id.String()] <= 0 {
		delete(s.compActive, id.String())
	}
}

func (s *Service) touchComputer(ctx context.Context, id identity.ID) {
	var c models.Computer
	if err := s.R.Get(ctx, "dev_computers", id, &c); err != nil {
		return
	}
	c.LastActiveAt = s.now()
	_ = s.R.Update(ctx, "dev_computers", id, &c)
}

// UploadToComputer copies a stored file onto a running computer, into /workspace.
func (s *Service) UploadToComputer(ctx context.Context, org identity.ID, id, fileID, dest string) error {
	file, data, err := s.fileBytes(ctx, org, fileID)
	if err != nil {
		return err
	}
	if dest = strings.TrimSpace(dest); dest == "" {
		dest = file.Name
	}
	dest = path.Clean("/workspace/" + strings.TrimPrefix(dest, "/"))
	if !strings.HasPrefix(dest, "/workspace/") {
		return errs.InvalidArgument("path must stay inside /workspace.")
	}
	if _, err := s.Exec(ctx, org, id, "mkdir -p "+shQuote(path.Dir(dest))+" && : > "+shQuote(dest), 0); err != nil {
		return err
	}
	// A shell argument is short: the file goes over in chunks.
	const chunk = 45 << 10
	for off := 0; off < len(data); off += chunk {
		end := min(off+chunk, len(data))
		cmd := "printf %s '" + base64.StdEncoding.EncodeToString(data[off:end]) + "' | base64 -d >> " + shQuote(dest)
		if res, err := s.Exec(ctx, org, id, cmd, 0); err != nil {
			return err
		} else if res.ExitCode != 0 {
			return errs.New(errs.CodeUnavailable, "The file could not be written on the computer: "+clip(res.Stdout, 200))
		}
	}
	return nil
}

func shQuote(text string) string { return "'" + strings.ReplaceAll(text, "'", `'\''`) + "'" }

// MeterComputers is the computers' clock: it charges the time running
// computers have used, stops the idle ones and the ones past their lifetime,
// and stops any whose organization can no longer pay.
func (s *Service) MeterComputers(ctx context.Context) {
	var running []models.Computer
	if err := s.R.List(ctx, "dev_computers", database.Filter{Equal: map[string]any{"status": computerRunning}}, &running); err != nil {
		return
	}
	m, _ := s.Infra.Machine(ctx)
	for _, c := range running {
		s.compMu.Lock()
		cur, err := s.loadComputer(ctx, c.OrgID, c.ID.String())
		if err != nil || cur.Status != computerRunning {
			s.compMu.Unlock()
			continue
		}
		s.compActMu.Lock()
		busy := s.compActive[cur.ID.String()] > 0
		s.compActMu.Unlock()
		now := s.now()
		switch {
		case !busy && now.Sub(cur.LastActiveAt) >= IdleStop:
			s.L.Info("developer: stopping an idle computer", "computer", cur.ID.String())
			_ = s.stopLocked(ctx, cur)
		case m.MaxLifetimeMin > 0 && now.Sub(cur.RunStartedAt) >= time.Duration(m.MaxLifetimeMin)*time.Minute:
			s.L.Info("developer: stopping a computer at its lifetime", "computer", cur.ID.String())
			_ = s.stopLocked(ctx, cur)
		default:
			if err := s.billRun(ctx, cur, false); err != nil {
				s.L.Info("developer: stopping a computer its organization cannot pay for", "computer", cur.ID.String(), "error", err)
				_ = s.stopLocked(ctx, cur)
				break
			}
			_ = s.R.Update(ctx, "dev_computers", cur.ID, cur)
		}
		s.compMu.Unlock()
	}
}
