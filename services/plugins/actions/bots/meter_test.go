package bots

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/config"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

// fakeVMM is a minimal vmm.VMM that reports a fixed cumulative token counter,
// used to exercise the per-request usage metering without a real provider.
type fakeVMM struct {
	base.Base
	tokensIn  int64
	tokensOut int64
}

func (f *fakeVMM) Name() string                                   { return "fakevmm" }
func (f *fakeVMM) SupportedTypes() []vmm.Type                     { return []vmm.Type{vmm.TypeDeepAgents} }
func (f *fakeVMM) Open(ctx context.Context, cfg vmm.Config) error { return nil }
func (f *fakeVMM) Close(ctx context.Context) error                { return nil }
func (f *fakeVMM) Health(ctx context.Context) vmm.Health          { return vmm.Health{OK: true} }
func (f *fakeVMM) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	return vmm.Image{ID: "img-1", Ref: "agent"}, nil
}
func (f *fakeVMM) DeleteImage(ctx context.Context, ref string) error { return nil }
func (f *fakeVMM) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	return vmm.VM{ID: "vm-1", Name: spec.Name, Type: vmm.TypeDeepAgents, Status: vmm.StatusRunning}, nil
}
func (f *fakeVMM) DeleteVM(ctx context.Context, id string) error { return nil }
func (f *fakeVMM) StartVM(ctx context.Context, id string) error  { return nil }
func (f *fakeVMM) StopVM(ctx context.Context, id string) error   { return nil }
func (f *fakeVMM) PauseVM(ctx context.Context, id string) error  { return nil }
func (f *fakeVMM) ResumeVM(ctx context.Context, id string) error { return nil }
func (f *fakeVMM) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	return vmm.VM{ID: id}, nil
}
func (f *fakeVMM) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	return vmm.VM{ID: id, Status: vmm.StatusRunning}, nil
}
func (f *fakeVMM) ListVMs(ctx context.Context, filter vmm.Filter) ([]vmm.VM, error) { return nil, nil }
func (f *fakeVMM) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	return vmm.Usage{VMID: id, TokensIn: f.tokensIn, TokensOut: f.tokensOut}, nil
}
func (f *fakeVMM) Init(ctx context.Context, deps *api.Dependencies) error { return nil }
func (f *fakeVMM) Start(ctx context.Context) error                        { return nil }
func (f *fakeVMM) Stop(ctx context.Context) error                         { return nil }

type fakeRecorder struct {
	rows []usage.Usage
}

func (f *fakeRecorder) Record(_ context.Context, u *usage.Usage) error {
	f.rows = append(f.rows, *u)
	return nil
}

func meterHarness(t *testing.T) (*Service, *fakeVMM, *fakeRecorder, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(),
		Config: dconfig.NewProvider(&dconfig.Config{})})
	r := &repo.Repo{DB: db}
	s := NewService(k, r, logger.Global())
	vm := &fakeVMM{Base: base.Base{Name: "fakevmm", Category: api.CategoryVMM, Version: "1.0.0"}}
	if err := k.Register(vm); err != nil {
		t.Fatal(err)
	}
	if err := k.Boot(ctx, []string{"fakevmm"}); err != nil {
		t.Fatal(err)
	}
	rec := &fakeRecorder{}
	s.UsageLog = rec
	return s, vm, rec, ctx
}

func TestRecordUsageMetersPerRequestDelta(t *testing.T) {
	s, vm, rec, ctx := meterHarness(t)
	space := mustID(t, "00000000000000010000000000000001")
	room := mustID(t, "00000000000000010000000000000002")
	actor := mustID(t, "00000000000000010000000000000003")
	owner, botID := entityHarnessIDs(t, s, ctx)
	_ = owner

	vm.tokensIn = 100
	vm.tokensOut = 20
	uc := usage.UsageCtx{SpaceID: space, RoomID: room, BotName: "AlphaBot", RequestID: "req-1", Kind: usage.KindAsk}
	d, err := s.RecordUsage(ctx, actor, botID, uc)
	if err != nil {
		t.Fatal(err)
	}
	if d.TokensIn != 100 || d.TokensOut != 20 {
		t.Fatalf("delta = %+v, want 100/20", d)
	}
	if len(rec.rows) != 1 {
		t.Fatalf("expected 1 recorded row, got %d", len(rec.rows))
	}
	if rec.rows[0].SpaceID != space || rec.rows[0].RoomID != room || rec.rows[0].BotID != botID {
		t.Fatalf("row attribution wrong: %+v", rec.rows[0])
	}

	// Second request only meters the new tokens.
	vm.tokensIn = 130
	vm.tokensOut = 25
	d2, err := s.RecordUsage(ctx, actor, botID, uc)
	if err != nil {
		t.Fatal(err)
	}
	if d2.TokensIn != 30 || d2.TokensOut != 5 {
		t.Fatalf("delta2 = %+v, want 30/5", d2)
	}
	if len(rec.rows) != 2 {
		t.Fatalf("expected 2 recorded rows, got %d", len(rec.rows))
	}
}

// entityHarnessIDs creates a langchain bot with a VM so Usage() resolves.
func entityHarnessIDs(t *testing.T, s *Service, ctx context.Context) (identity.ID, identity.ID) {
	t.Helper()
	owner, _ := identity.New(1)
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "AlphaBot", Kind: bot.KindAgent,
		VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning, VMID: "vm-1",
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	return owner, botID
}
