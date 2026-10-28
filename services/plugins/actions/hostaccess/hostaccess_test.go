package hostaccess

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	hm "github.com/aseman/aseman/plugins/actions/hostaccess/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
)

const ownerHex = "00000000000000010000000000000001"

func harness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range hm.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	s := NewService(kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()}), &repo.Repo{DB: db}, logger.Global())
	s.PollWait, s.CallTimeout = 2*time.Second, 2*time.Second
	return s, ctx
}

func TestAgentCallsReachTheDesktopApp(t *testing.T) {
	s, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	if _, err := s.Register(ctx, owner, "", "Sam's laptop", "macos", []string{"/"}); err == nil {
		t.Fatal("a whole disk is not a shared folder")
	}
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); len(tools) != 0 {
		t.Fatal("no tools before a computer connects")
	}
	h, err := s.Register(ctx, owner, "", "Sam's laptop", "macos", []string{"/Users/sam/Invoices"})
	if err != nil {
		t.Fatal(err)
	}
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); len(tools) != 4 {
		t.Fatal("host tools once it polls")
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "host_read", Args: `{"path":"/Users/sam/.ssh/id_rsa"}`, ActorID: ownerHex}); err == nil {
		t.Fatal("outside the shared folders is refused")
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "host_read", Args: `{"path":"/Users/sam/Invoices/../.ssh/id_rsa"}`, ActorID: ownerHex}); err == nil {
		t.Fatal("dot-dot does not escape")
	}
	// The desktop app answers the call the agent makes.
	go func() {
		c, err := s.Next(ctx, owner, h.ID.String())
		if err != nil || c == nil {
			t.Errorf("no call: %v", err)
			return
		}
		_ = s.Result(ctx, owner, c.ID.String(), "invoice,amount\n001,40", "")
	}()
	out, err := s.AgentTool(ctx, gate.ToolCall{Tool: "host_read", Args: `{"path":"/Users/sam/Invoices/oct.csv"}`, ActorID: ownerHex, AgentName: "aseman"})
	if err != nil || !strings.Contains(out, "001,40") || !strings.Contains(out, "untrusted_data") {
		t.Fatalf("%q %v", out, err)
	}
	// Nobody answers: the call expires.
	s.CallTimeout = 50 * time.Millisecond
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "host_list", Args: `{}`, ActorID: ownerHex}); err == nil {
		t.Fatal("an unanswered call fails")
	}
}
