package bots

import (
	"context"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	dconfig "github.com/tradera/tradera/plugins/config"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

// fakeMCP is the MCP tool adapter: a tool call is its Send.
type fakeMCP struct {
	fakeVMM
	calls []string
}

func (f *fakeMCP) Name() string               { return "fakemcp" }
func (f *fakeMCP) SupportedTypes() []vmm.Type { return []vmm.Type{vmm.TypeMCP} }
func (f *fakeMCP) Send(_ context.Context, vmID, body string) (string, error) {
	f.calls = append(f.calls, vmID+":"+body)
	return `{"content":[{"text":"sunny"}]}`, nil
}

// A remote MCP tool is called through the bot service like any other bot: its
// VM's Send runs the call. (MCP bots once fell through to "does not support
// messaging", which made every tool call fail.)
func TestSendMessageCallsMCPTools(t *testing.T) {
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Config: dconfig.NewProvider(&dconfig.Config{})})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	vm := &fakeMCP{fakeVMM: fakeVMM{Base: base.Base{Name: "fakemcp", Category: api.CategoryVMM, Version: "1.0.0"}}}
	if err := k.Register(vm); err != nil {
		t.Fatal(err)
	}
	if err := k.Boot(ctx, []string{"fakemcp"}); err != nil {
		t.Fatal(err)
	}
	id, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: id, Name: "weather",
		Kind: bot.KindTool, VMType: bot.VMType("mcp"), VMID: "mcp-1", Status: bot.StatusRunning, SpecYML: "http://tool"}
	if err := s.R.CreateID(ctx, "bots", id, rec); err != nil {
		t.Fatal(err)
	}
	reply, err := s.SendMessage(ctx, id, `{"function":"weather"}`, nil, nil)
	if err != nil || reply != `{"content":[{"text":"sunny"}]}` || len(vm.calls) != 1 || vm.calls[0] != `mcp-1:{"function":"weather"}` {
		t.Fatalf("SendMessage = %q, %v (calls %v)", reply, err, vm.calls)
	}
}
