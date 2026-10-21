package runtime_test

import (
	"context"
	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/config"
	"testing"
)

type agentProvider struct {
	vmm.VMM
	base.Base
}

func (p *agentProvider) Name() string                                      { return "agent-provider" }
func (p *agentProvider) Init(context.Context, *api.Dependencies) error     { return nil }
func (p *agentProvider) Start(context.Context) error                       { return nil }
func (p *agentProvider) Stop(context.Context) error                        { return nil }
func (p *agentProvider) SupportedTypes() []vmm.Type                        { return []vmm.Type{vmm.TypeDeepAgents} }
func (p *agentProvider) EnsureAgent(context.Context, string, string) error { return nil }
func (p *agentProvider) Prompt(ctx context.Context, id string, turn vmm.AgentTurn) (string, error) {
	return "prompt:" + turn.Message, nil
}
func (p *agentProvider) Observe(context.Context, string, vmm.AgentTurn) error { return nil }
func (p *agentProvider) Reply(ctx context.Context, id string, turn vmm.AgentTurn) (bool, string, error) {
	return true, "resumed:" + turn.QuestionID, nil
}
func (p *agentProvider) Questions(ctx context.Context, id, spaceID string) ([]vmm.AgentQuestion, error) {
	return []vmm.AgentQuestion{{ID: "q1", SpaceID: spaceID}}, nil
}

func TestGuardPreservesAgentCapabilities(t *testing.T) {
	ctx := context.Background()
	k := kernel.New(kernel.Options{Config: dconfig.NewProvider(&dconfig.Config{})})
	provider := &agentProvider{Base: base.Base{Name: "agent-provider", Category: api.CategoryVMM}}
	if err := k.Register(provider); err != nil {
		t.Fatal(err)
	}
	if err := k.Init(provider.Info().Name); err != nil {
		t.Fatal(err)
	}
	if err := k.Start(provider.Info().Name); err != nil {
		t.Fatal(err)
	}
	vm := k.VMMFor(vmm.TypeDeepAgents)
	rt, ok := vm.(vmm.AgentRuntime)
	if !ok {
		t.Fatal("agent runtime contract lost")
	}
	reply, err := rt.Prompt(ctx, "id", vmm.AgentTurn{Message: "hello"})
	if err != nil || reply != "prompt:hello" {
		t.Fatalf("reply=%q err=%v", reply, err)
	}
	answered, resumed, err := rt.Reply(ctx, "id", vmm.AgentTurn{QuestionID: "q1"})
	if err != nil || !answered || resumed != "resumed:q1" {
		t.Fatalf("answered=%v resumed=%q err=%v", answered, resumed, err)
	}
	lister, ok := vm.(vmm.QuestionLister)
	if !ok {
		t.Fatal("question lister contract lost")
	}
	if qs, err := lister.Questions(ctx, "id", "space"); err != nil || len(qs) != 1 || qs[0].SpaceID != "space" {
		t.Fatalf("questions=%v err=%v", qs, err)
	}
	if err := k.Stop(provider.Info().Name); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.Prompt(ctx, "id", vmm.AgentTurn{Message: "hello"}); err == nil {
		t.Fatal("stale agent reference callable")
	}
}
