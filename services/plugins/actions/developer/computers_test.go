package developer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/textproto"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/filesystem/ports"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// fakeVMM is a computer provider that keeps machines in memory.
type fakeVMM struct {
	vmm.VMM
	mu      sync.Mutex
	vms     map[string]string // id -> status
	specs   map[string]vmm.VMSpec
	history []string
	files   map[string]string // path -> content, from commands that write
	nextID  int
}

func newVMM() *fakeVMM {
	return &fakeVMM{vms: map[string]string{}, specs: map[string]vmm.VMSpec{}, files: map[string]string{}}
}

func (f *fakeVMM) log(op string) { f.history = append(f.history, op) }
func (f *fakeVMM) CreateVM(_ context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	id := fmt.Sprintf("vm-%d", f.nextID)
	f.vms[id], f.specs[id] = "created", spec
	f.log("create " + spec.Name)
	return vmm.VM{ID: id, Name: spec.Name}, nil
}
func (f *fakeVMM) StartVM(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.vms[id]; !ok {
		return errs.NotFound("vm")
	}
	f.vms[id] = "running"
	f.log("start " + id)
	return nil
}
func (f *fakeVMM) StopVM(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.vms[id] = "stopped"
	f.log("stop " + id)
	return nil
}
func (f *fakeVMM) DeleteVM(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.vms, id)
	f.log("delete " + id)
	return nil
}
func (f *fakeVMM) DeleteWorkspaceVolume(_ context.Context, machine string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log("volume " + machine)
	return nil
}
func (f *fakeVMM) Send(_ context.Context, id, command string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.vms[id] != "running" {
		return "", errs.New(errs.CodeVMM, "not running")
	}
	switch {
	case strings.Contains(command, "exit 3"):
		return "exit=3\nboom", errs.New(vmm.CodeToolExecutionFailed, "exited with status 3")
	case strings.Contains(command, "base64 -d >>"):
		// printf %s '<b64>' | base64 -d >> 'dest'
		b64 := command[strings.Index(command, "'")+1:]
		b64 = b64[:strings.Index(b64, "'")]
		raw, _ := base64.StdEncoding.DecodeString(b64)
		dest := command[strings.LastIndex(command, ">> ")+4:]
		dest = strings.TrimSuffix(dest, "'")
		f.files[dest] += string(raw)
		return "exit=0\n(no output)", nil
	case strings.Contains(command, ": >"):
		return "exit=0\n(no output)", nil
	}
	return "exit=0\nhello from " + id + "\n", nil
}

type fakeInfra struct{ owner identity.ID }

func (fakeInfra) Machine(context.Context) (MachineSettings, error) {
	return MachineSettings{CPU: 2, MemoryMB: 2048, DiskMB: 4096, MaxCPU: 4, MaxMemoryMB: 8192, MaxLifetimeMin: 480, CommandTimeoutSec: 300}, nil
}

// $0.0001 a minute, and $0.0002 per vCPU, $0.0001 per GB of memory, $0 for disk: in ledger units.
func (fakeInfra) Rate(context.Context) (ComputerRate, error) {
	return ComputerRate{PerMinute: 100, CPUPerMin: 200, MemoryPerGBMin: 100}, nil
}
func (fakeInfra) StoragePrice(context.Context) (int64, error) { return 73_000, nil } // $0.073 a GB-month
func (i fakeInfra) NodeOwner(context.Context) identity.ID     { return i.owner }

type memFS struct {
	mu   sync.Mutex
	data map[string][]byte
}

func (m *memFS) Name() string                                  { return "mem" }
func (m *memFS) Open(context.Context, filesystem.Config) error { return nil }
func (m *memFS) Close(context.Context) error                   { return nil }
func (m *memFS) Health(context.Context) filesystem.Health      { return filesystem.Health{OK: true} }
func (m *memFS) Put(_ context.Context, key string, r io.Reader, _ int64, _ string) error {
	b, _ := io.ReadAll(r)
	m.mu.Lock()
	m.data[key] = b
	m.mu.Unlock()
	return nil
}
func (m *memFS) Get(_ context.Context, key string) (io.ReadCloser, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.data[key]
	if !ok {
		return nil, errs.NotFound("object")
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}
func (m *memFS) Delete(_ context.Context, key string) error {
	m.mu.Lock()
	delete(m.data, key)
	m.mu.Unlock()
	return nil
}
func (m *memFS) Stat(context.Context, string) (filesystem.ObjectInfo, error) {
	return filesystem.ObjectInfo{}, nil
}
func (m *memFS) Exists(_ context.Context, key string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.data[key]
	return ok, nil
}
func (m *memFS) List(context.Context, string) ([]filesystem.ObjectInfo, error) { return nil, nil }

func computerFixture(t *testing.T) (*fixture, *fakeVMM, *memFS, identity.ID) {
	t.Helper()
	f := harness(t)
	v, store := newVMM(), &memFS{data: map[string][]byte{}}
	owner, _ := identity.New(1)
	f.fin.balance[owner] = 0
	f.s.Infra = fakeInfra{owner: owner}
	f.s.VMs = func(vmm.Type) vmm.VMM { return v }
	f.s.FS = func() filesystem.FileStorage { return store }
	return f, v, store, owner
}

func TestComputerOptionsAreTheNodesRealLimits(t *testing.T) {
	f, _, _, _ := computerFixture(t)
	o, err := f.s.ComputerOptions(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if o.CPU.Min != 0.25 || o.CPU.Max != 4 || o.CPU.Step != 0.25 || o.CPU.Default != 2 || o.MemoryMB.Max != 8192 || o.MemoryMB.Min != 512 || o.MemoryMB.Step != 256 {
		t.Fatalf("%+v", o)
	}
	if o.Burst.CPU != 4 || o.Burst.MemoryMB != 8192 || o.IdleStopMin != 2 || o.MaxLifetimeMin != 480 || o.CommandTimeoutSec != 300 || len(o.Images) != 1 || o.Images[0].ID != DefaultImage {
		t.Fatalf("%+v", o)
	}
}

func TestAComputerIsCreatedWithinLimitsRunsCommandsAndIsBilledByTheMinute(t *testing.T) {
	f, v, _, owner := computerFixture(t)
	org := f.me
	if _, err := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{Spec: ComputerSpec{CPU: 9, MemoryMB: 1024}}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("too many cores: %v", err)
	}
	if _, err := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{Spec: ComputerSpec{CPU: 1, MemoryMB: 64}}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("too little memory: %v", err)
	}
	if _, err := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{Image: "bad image; rm -rf /"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an image is a reference: %v", err)
	}
	c, err := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{Name: "build", Spec: ComputerSpec{CPU: 1.1, MemoryMB: 1000}})
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "running" || c.Spec.CPU != 1 || c.Spec.MemoryMB != 1024 || c.Image != DefaultImage {
		t.Fatalf("sizes snap to their steps: %+v", c)
	}
	spec := v.specs["vm-1"]
	if !strings.HasPrefix(spec.Name, "sbx-dev-") || spec.Type != vmm.TypeContainer || spec.Resources.CPU != 1 || spec.Resources.MemoryMB != 1024 || spec.Labels["tradera.bot_id"] == "" {
		t.Fatalf("spec: %+v", spec)
	}
	res, err := f.s.Exec(f.ctx, org, c.ID, "echo hi", 0)
	if err != nil || res.ExitCode != 0 || !strings.Contains(res.Stdout, "hello from vm-1") {
		t.Fatalf("%v %+v", err, res)
	}
	if res, err := f.s.Exec(f.ctx, org, c.ID, "exit 3", 0); err != nil || res.ExitCode != 3 || res.Stdout != "boom" {
		t.Fatalf("a failing command is a result: %v %+v", err, res)
	}
	// 1 vCPU, 1 GB: 100 + 200 + 100 = 400 units a minute. Five minutes: 2,000.
	f.now = f.now.Add(5 * time.Minute)
	if _, err := f.s.Exec(f.ctx, org, c.ID, "echo hi", 0); err != nil {
		t.Fatal(err)
	}
	if got, err := f.s.SetComputerStatus(f.ctx, org, c.ID, "stopped"); err != nil || got.Status != "stopped" || got.Minutes != 5 {
		t.Fatalf("%v %+v", err, got)
	}
	if f.fin.billed[org] != 2000 || f.fin.charges[len(f.fin.charges)-1].Payees[0] != owner {
		t.Fatalf("billed %v, paid to %+v", f.fin.billed, f.fin.charges)
	}
	if _, err := f.s.Exec(f.ctx, org, c.ID, "echo hi", 0); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("a stopped computer runs nothing: %v", err)
	}
	if _, err := f.s.SetComputerStatus(f.ctx, org, c.ID, "running"); err != nil {
		t.Fatal(err)
	}
	// Another organization cannot see it.
	other, _ := identity.New(1)
	if _, err := f.s.Computer(f.ctx, other, c.ID); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("%v", err)
	}
	if err := f.s.DeleteComputer(f.ctx, org, c.ID); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(v.history, ","); !strings.Contains(got, "delete vm-1") || !strings.Contains(got, "volume sbx-dev-") {
		t.Fatalf("the machine and its volume go: %s", got)
	}
	if list, _ := f.s.Computers(f.ctx, org); len(list) != 0 {
		t.Fatal("deleted")
	}
}

func TestTheMeterChargesAsItGoesAndStopsIdleOrUnpaidComputers(t *testing.T) {
	f, v, _, _ := computerFixture(t)
	org := f.me
	c, _ := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{Spec: ComputerSpec{CPU: 1, MemoryMB: 1024}}) // 400 units a minute
	f.now = f.now.Add(90 * time.Second)
	f.s.touchComputer(f.ctx, mustID(t, c.ID)) // a command a moment ago
	f.s.MeterComputers(f.ctx)
	if f.fin.billed[org] != 600 {
		t.Fatalf("90 s is 600 units: %d", f.fin.billed[org])
	}
	f.s.MeterComputers(f.ctx)
	if f.fin.billed[org] != 600 {
		t.Fatalf("nothing is charged twice: %d", f.fin.billed[org])
	}
	f.now = f.now.Add(3 * time.Minute) // past the idle window since the last command
	f.s.MeterComputers(f.ctx)
	got, _ := f.s.Computer(f.ctx, org, c.ID)
	if got.Status != "stopped" || !strings.Contains(strings.Join(v.history, ","), "stop vm-1") {
		t.Fatalf("an idle computer is stopped: %+v", got)
	}
	// 270 s in all: 1,800 units, charged to the unit.
	if f.fin.billed[org] != 1800 {
		t.Fatalf("billed %d", f.fin.billed[org])
	}
	// A running command keeps it up; no money stops it.
	if _, err := f.s.SetComputerStatus(f.ctx, org, c.ID, "running"); err != nil {
		t.Fatal(err)
	}
	f.s.activity(mustID(t, c.ID), 1)
	f.now = f.now.Add(10 * time.Minute)
	f.s.MeterComputers(f.ctx)
	if got, _ := f.s.Computer(f.ctx, org, c.ID); got.Status != "running" {
		t.Fatal("a computer with a command running is not idle")
	}
	f.s.activity(mustID(t, c.ID), -1)
	f.fin.balance[org] = 1_000 // enough to start, not to carry on
	f.now = f.now.Add(1 * time.Minute)
	f.s.touchComputer(f.ctx, mustID(t, c.ID))
	f.fin.balance[org] = 0
	f.fin.charges = nil
	f.fin.chargeErr = errs.New(errs.CodeFinance, "insufficient balance")
	f.s.MeterComputers(f.ctx)
	if got, _ := f.s.Computer(f.ctx, org, c.ID); got.Status != "stopped" {
		t.Fatalf("a computer that cannot be paid for is stopped: %+v", got)
	}
}

func TestComputersNeedFundsAndAreLimitedInNumber(t *testing.T) {
	f, _, _, _ := computerFixture(t)
	f.fin.balance[f.me] = 0
	if _, err := f.s.CreateComputer(f.ctx, f.me, f.me, ComputerInput{}); errs.CodeOf(err) != errs.CodeFinance {
		t.Fatalf("%v", err)
	}
	f.fin.balance[f.me] = 50_000_000
	for i := 0; i < MaxComputers; i++ {
		if _, err := f.s.CreateComputer(f.ctx, f.me, f.me, ComputerInput{}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.s.CreateComputer(f.ctx, f.me, f.me, ComputerInput{}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("the eleventh: %v", err)
	}
}

func TestFilesAreStoredPerOrganizationAndReachComputers(t *testing.T) {
	f, v, store, _ := computerFixture(t)
	org := f.me
	up, err := f.s.Upload(f.ctx, org, `C:\fakepath\../notes.txt`, "", "dataset", []byte("hello world"))
	if err != nil || up.Name != "notes.txt" || up.Size != 11 || up.Purpose != "dataset" || up.Mime == "" {
		t.Fatalf("%v %+v", err, up)
	}
	if len(store.data) != 1 {
		t.Fatal("the bytes are stored")
	}
	if _, err := f.s.Upload(f.ctx, org, "big", "", "", make([]byte, MaxFileBytes+1)); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("%v", err)
	}
	other, _ := identity.New(1)
	if _, _, err := f.s.ReadFile(f.ctx, other, up.ID); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("another organization's file does not exist: %v", err)
	}
	if got, data, err := f.s.ReadFile(f.ctx, org, up.ID); err != nil || string(data) != "hello world" || got.ID != up.ID {
		t.Fatalf("%v %q", err, data)
	}
	c, _ := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{})
	big := bytes.Repeat([]byte("0123456789"), 10_000) // 100 KB: several chunks
	bigFile, _ := f.s.Upload(f.ctx, org, "data.bin", "application/octet-stream", "", big)
	if err := f.s.UploadToComputer(f.ctx, org, c.ID, bigFile.ID, "in/data.bin"); err != nil {
		t.Fatal(err)
	}
	if got := v.files["/workspace/in/data.bin"]; got != string(big) {
		t.Fatalf("the file arrives whole, in pieces: %d bytes of %d", len(got), len(big))
	}
	if err := f.s.UploadToComputer(f.ctx, org, c.ID, bigFile.ID, "../../etc/passwd"); err == nil || v.files["/etc/passwd"] != "" {
		t.Fatalf("a path stays in /workspace: %v", err)
	}
	if list, _ := f.s.Files(f.ctx, org); len(list) != 2 {
		t.Fatalf("%+v", list)
	}
	if err := f.s.DeleteFile(f.ctx, org, up.ID); err != nil {
		t.Fatal(err)
	}
	if len(store.data) != 1 {
		t.Fatal("the bytes go with the file")
	}
}

func TestTheAPIServesComputersAndFiles(t *testing.T) {
	f, _, _, _ := computerFixture(t)
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "ci", Permissions: all})
	_, readOnly := f.key(t, f.personal(t), KeyInput{Name: "ro", Permissions: Permissions{Computers: LevelRead, Files: LevelRead}})
	call := func(token string, method network.Method, path, ctype string, body []byte) (int, map[string]any, *network.Response) {
		var handler network.Handler
		var params map[string]string
		for _, r := range f.s.routes() {
			if r.method != method {
				continue
			}
			if ok, p := matchRoute(r.pattern, apiPrefix+path); ok {
				handler, params = r.handler, p
				break
			}
		}
		if handler == nil {
			t.Fatalf("no route %s %s", method, path)
		}
		req := &network.Request{Method: method, Path: apiPrefix + path, Header: map[string]string{"Authorization": "Bearer " + token, "Content-Type": ctype}, Body: body, Query: map[string][]string{}}
		pb, _ := json.Marshal(params)
		req.Header["x-route-params"] = string(pb)
		resp, err := handler(f.ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		var out map[string]any
		_ = json.Unmarshal(resp.Body, &out)
		return resp.Status, out, resp
	}
	js := func(v any) []byte { b, _ := json.Marshal(v); return b }
	st, opts, _ := call(secret, network.MethodGet, "/computers/options", "", nil)
	if st != 200 || opts["cpu"].(map[string]any)["max"] != float64(4) || opts["pricing"].(map[string]any)["currency"] != "USD" {
		t.Fatalf("%d %v", st, opts)
	}
	st, made, _ := call(secret, network.MethodPost, "/computers", "application/json", js(map[string]any{"name": "api", "cpu": 0.5, "memory_mb": 512}))
	if st != 201 || made["status"] != "running" || made["memory_mb"] != float64(512) {
		t.Fatalf("%d %v", st, made)
	}
	id := made["id"].(string)
	if st, _, _ := call(readOnly, network.MethodPost, "/computers", "application/json", js(map[string]any{})); st != 403 {
		t.Fatalf("a read-only key cannot create: %d", st)
	}
	if st, list, _ := call(readOnly, network.MethodGet, "/computers", "", nil); st != 200 || len(list["data"].([]any)) != 1 {
		t.Fatalf("%d %v", st, list)
	}
	st, ran, _ := call(secret, network.MethodPost, "/computers/"+id+"/exec", "application/json", js(map[string]any{"command": "echo hi"}))
	if st != 200 || ran["exit_code"] != float64(0) || !strings.Contains(ran["stdout"].(string), "hello") {
		t.Fatalf("%d %v", st, ran)
	}
	if st, bad, _ := call(secret, network.MethodPost, "/computers", "application/json", js(map[string]any{"cpu": 64})); st != 400 || bad["error"].(map[string]any)["code"] != "invalid_request" {
		t.Fatalf("%d %v", st, bad)
	}
	if st, _, _ := call(secret, network.MethodGet, "/computers/nope", "", nil); st != 404 {
		t.Fatalf("%d", st)
	}
	if st, stopped, _ := call(secret, network.MethodPost, "/computers/"+id+"/stop", "", nil); st != 200 || stopped["status"] != "stopped" {
		t.Fatalf("%d %v", st, stopped)
	}
	if st, e, _ := call(secret, network.MethodPost, "/computers/"+id+"/exec", "application/json", js(map[string]any{"command": "ls"})); st != 409 {
		t.Fatalf("%d %v", st, e)
	}

	var form bytes.Buffer
	w := multipart.NewWriter(&form)
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", `form-data; name="file"; filename="customers.csv"`)
	h.Set("Content-Type", "text/csv")
	part, _ := w.CreatePart(h)
	_, _ = part.Write([]byte("a,b\n1,2\n"))
	_ = w.WriteField("purpose", "dataset")
	_ = w.Close()
	st, file, _ := call(secret, network.MethodPost, "/files", w.FormDataContentType(), form.Bytes())
	if st != 201 || file["name"] != "customers.csv" || file["mime"] != "text/csv" || file["purpose"] != "dataset" || file["size"] != float64(8) {
		t.Fatalf("%d %v", st, file)
	}
	fid := file["id"].(string)
	if st, _, raw := call(secret, network.MethodGet, "/files/"+fid+"/content", "", nil); st != 200 || string(raw.Body) != "a,b\n1,2\n" || raw.Header["Content-Type"] != "text/csv" {
		t.Fatalf("%d %q %v", st, raw.Body, raw.Header)
	}
	if st, e, _ := call(secret, network.MethodPost, "/files", "application/json", []byte("{}")); st != 400 {
		t.Fatalf("%d %v", st, e)
	}
	if st, _, _ := call(readOnly, network.MethodDelete, "/files/"+fid, "", nil); st != 403 {
		t.Fatalf("%d", st)
	}
	if st, gone, _ := call(secret, network.MethodDelete, "/files/"+fid, "", nil); st != 200 || gone["deleted"] != true {
		t.Fatalf("%d %v", st, gone)
	}
	if st, _, _ := call(secret, network.MethodDelete, "/computers/"+id, "", nil); st != 200 {
		t.Fatalf("%d", st)
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{Service: "computers"}, 50)
	storage, _ := f.s.Logs(f.ctx, f.me, LogFilter{Service: "storage"}, 50)
	if len(logs) < 6 || len(storage) < 4 || logs[0].KeyName == "" {
		t.Fatalf("calls are logged by service: %d %d", len(logs), len(storage))
	}
}

func matchRoute(pattern, path string) (bool, map[string]string) {
	a, b := strings.Split(pattern, "/"), strings.Split(path, "/")
	if len(a) != len(b) {
		return false, nil
	}
	params := map[string]string{}
	for i := range a {
		if strings.HasPrefix(a[i], "{") {
			params[strings.Trim(a[i], "{}")] = b[i]
		} else if a[i] != b[i] {
			return false, nil
		}
	}
	return true, params
}

func TestStorageIsChargedByTheHourForWhatIsHeld(t *testing.T) {
	f, _, _, owner := computerFixture(t)
	org := f.me
	// Four GB would be $0.292 a month at $0.073: 1 GiB is enough to see the maths, held in one file's size.
	data := make([]byte, 1<<20) // 1 MiB, stored 1,024 times over in size terms below
	up, err := f.s.Upload(f.ctx, org, "a.bin", "application/octet-stream", "", data)
	if err != nil {
		t.Fatal(err)
	}
	row, _ := f.s.loadFile(f.ctx, org, up.ID)
	row.Size = 10 << 30 // pretend ten GiB are held: $0.73 a month
	if err := f.s.R.Update(f.ctx, "dev_files", row.ID, row); err != nil {
		t.Fatal(err)
	}
	info, _ := f.s.Storage(f.ctx, org)
	if info.UsedBytes != 10<<30 || info.PriceGBMonth != 73_000 || info.PerMonth != 730_000 || info.Files != 1 {
		t.Fatalf("%+v", info)
	}
	f.s.MeterStorage(f.ctx) // starts the clock; nothing is charged for time before it
	if f.fin.billed[org] != 0 {
		t.Fatalf("billed at the start: %d", f.fin.billed[org])
	}
	f.now = f.now.Add(30 * time.Minute)
	f.s.MeterStorage(f.ctx)
	if f.fin.billed[org] != 0 {
		t.Fatal("charged is by the hour")
	}
	f.now = f.now.Add(30 * time.Minute) // one hour: 730,000 / 730 = 1,000 units
	f.s.MeterStorage(f.ctx)
	if f.fin.billed[org] != 1000 || f.fin.charges[len(f.fin.charges)-1].Payees[0] != owner {
		t.Fatalf("an hour of 10 GiB: %d", f.fin.billed[org])
	}
	// A fraction of a unit is carried, not lost: 1 GiB for 3 hours is 300 units; half an hour more adds the carry.
	row.Size = 1 << 30
	_ = f.s.R.Update(f.ctx, "dev_files", row.ID, row)
	before := f.fin.billed[org]
	for i := 0; i < 5; i++ {
		f.now = f.now.Add(time.Hour)
		f.s.MeterStorage(f.ctx)
	}
	if got := f.fin.billed[org] - before; got != 500 { // 73,000 / 730 = 100 a hour
		t.Fatalf("five hours of 1 GiB: %d", got)
	}
	// An organization that cannot pay is not charged and cannot add files, but keeps them.
	f.fin.chargeErr = errs.New(errs.CodeFinance, "insufficient balance")
	f.now = f.now.Add(time.Hour)
	f.s.MeterStorage(f.ctx)
	f.fin.balance[org] = 0
	if _, err := f.s.Upload(f.ctx, org, "b.bin", "", "", []byte("x")); errs.CodeOf(err) != errs.CodeFinance {
		t.Fatalf("no new files without funds: %v", err)
	}
	if list, _ := f.s.Files(f.ctx, org); len(list) != 1 {
		t.Fatal("files are kept")
	}
	// No time is forgiven: when the money is back, the hours not charged are.
	f.fin.chargeErr = nil
	f.fin.balance[org] = 50_000_000
	before = f.fin.billed[org]
	f.s.MeterStorage(f.ctx)
	if f.fin.billed[org]-before != 100 {
		t.Fatalf("the missed hour is charged: %d", f.fin.billed[org]-before)
	}
}

func TestDeletingAnOrganizationDeletesItsComputersAndFiles(t *testing.T) {
	f, v, store, _ := computerFixture(t)
	team, _ := f.s.CreateOrg(f.ctx, f.me, "Cleanup")
	sc, _ := f.s.Scope(f.ctx, f.me, team.ID)
	f.fin.balance[sc.Org] = 10_000_000
	org := sc.Org
	if _, err := f.s.CreateComputer(f.ctx, org, f.me, ComputerInput{}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.Upload(f.ctx, org, "x.txt", "", "", []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if err := f.s.DeleteOrg(f.ctx, f.me, sc); err != nil {
		t.Fatal(err)
	}
	if len(store.data) != 0 || len(v.vms) != 0 || !strings.Contains(strings.Join(v.history, ","), "delete vm-1") {
		t.Fatalf("files %d, machines %v, %v", len(store.data), v.vms, v.history)
	}
}
