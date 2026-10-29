package hostaccess

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
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

func TestHostAccessIsOffUntilAnAdminTurnsItOn(t *testing.T) {
	s, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	if s.HostEnabled(ctx) {
		t.Fatal("off by default")
	}
	if _, err := s.Register(ctx, owner, "", "Sam's laptop", "macos", []string{"/Users/sam/Invoices"}); err == nil {
		t.Fatal("no computer registers while host access is off")
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "host_list", Args: `{}`, ActorID: ownerHex}); err == nil {
		t.Fatal("host tools refuse while it is off")
	}
	if _, err := s.SetHostEnabled(ctx, owner, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Register(ctx, owner, "", "Sam's laptop", "macos", []string{"/Users/sam/Invoices"}); err != nil {
		t.Fatal(err)
	}
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); len(tools) != 4 {
		t.Fatalf("host tools while on: %v", tools)
	}
	// Turning it off disconnects every computer, and they stay off.
	if _, err := s.SetHostEnabled(ctx, owner, false); err != nil {
		t.Fatal(err)
	}
	_, _ = s.SetHostEnabled(ctx, owner, true)
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); len(tools) != 0 {
		t.Fatalf("each person turns theirs on again: %v", tools)
	}
}

// fakeFiles is one project computer's workspace.
type fakeFiles struct {
	files  map[string]string
	member bool
}

func (f *fakeFiles) ProjectFiles(_ context.Context, _ identity.ID, space, op, p, content string) (map[string]any, error) {
	if !f.member {
		return nil, errs.Permission("not a member of the project")
	}
	switch op {
	case "list":
		if p == "missing" {
			return map[string]any{"ok": false, "missing": true}, nil
		}
		// As the bridge delivers it: decoded JSON.
		items := []any{}
		for name := range f.files {
			if strings.HasPrefix(name, p+"/") {
				items = append(items, map[string]any{"name": strings.TrimPrefix(name, p+"/"), "type": "file", "size": len(f.files[name])})
			}
		}
		return map[string]any{"items": items}, nil
	case "read":
		c, ok := f.files[p]
		if !ok {
			return map[string]any{"ok": false, "missing": true}, nil
		}
		return map[string]any{"content": c}, nil
	case "write":
		f.files[p] = content
		return map[string]any{"ok": true}, nil
	}
	return nil, errs.InvalidArgument(op)
}

func TestFoldersAreSharedFromProjectComputers(t *testing.T) {
	s, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	files := &fakeFiles{files: map[string]string{"invoices/oct.csv": "001,40", "secrets/key": "x"}}
	s.Files = files
	const space = "00000000000000010000000000000050"
	if _, err := s.ShareFolder(ctx, owner, space, "invoices", "", "read"); err == nil {
		t.Fatal("only a project the person can read")
	}
	files.member = true
	if _, err := s.ShareFolder(ctx, owner, space, "../etc", "", "read"); err == nil {
		t.Fatal("never outside the workspace")
	}
	if _, err := s.ShareFolder(ctx, owner, space, "missing", "", "read"); err == nil {
		t.Fatal("a folder that is not there")
	}
	f, err := s.ShareFolder(ctx, owner, space, "/workspace/invoices", "", "")
	if err != nil || f.Name != "invoices" || f.Access != hm.AccessRead || f.Path != "invoices" {
		t.Fatalf("%+v %v", f, err)
	}
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); strings.Join(tools, ",") != "folder_list,folder_read,folder_write" {
		t.Fatalf("folder tools once something is shared, no host tools: %v", tools)
	}
	out, err := s.AgentTool(ctx, gate.ToolCall{Tool: "folder_read", Args: `{"folder":"invoices","path":"oct.csv"}`, ActorID: ownerHex})
	if err != nil || !strings.Contains(out, "001,40") || !strings.Contains(out, "untrusted_data") {
		t.Fatalf("%q %v", out, err)
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "folder_read", Args: `{"folder":"invoices","path":"../secrets/key"}`, ActorID: ownerHex}); err == nil {
		t.Fatal("no way out of the shared folder")
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "folder_write", Args: `{"folder":"invoices","path":"x.md","content":"y"}`, ActorID: ownerHex}); err == nil {
		t.Fatal("read-only refuses writes")
	}
	if _, err := s.SetFolder(ctx, owner, f.ID.String(), hm.AccessWrite, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "folder_write", Args: `{"folder":"invoices","path":"nov.csv","content":"002,10"}`, ActorID: ownerHex}); err != nil || files.files["invoices/nov.csv"] != "002,10" {
		t.Fatalf("writes land in the project computer: %v", err)
	}
	other := "00000000000000010000000000000009"
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "folder_read", Args: `{"folder":"invoices","path":"oct.csv"}`, ActorID: other}); err == nil {
		t.Fatal("only the person's own agents")
	}
	if err := s.Unshare(ctx, owner, f.ID.String()); err != nil {
		t.Fatal(err)
	}
	if tools, _ := s.AvailableTools(ctx, ownerHex, ""); len(tools) != 0 {
		t.Fatalf("%v", tools)
	}
}

func TestAgentCallsReachTheDesktopApp(t *testing.T) {
	s, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	if _, err := s.SetHostEnabled(ctx, owner, true); err != nil {
		t.Fatal(err)
	}
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

func TestAFolderIsAttachedToAPrompt(t *testing.T) {
	s, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	other, _ := identity.Parse("00000000000000010000000000000009")
	files := &fakeFiles{member: true, files: map[string]string{"invoices/oct.csv": "001,40", "invoices/nov.csv": "002,10"}}
	s.Files = files
	f, err := s.ShareFolder(ctx, owner, "00000000000000010000000000000050", "invoices", "", "read")
	if err != nil {
		t.Fatal(err)
	}
	ref := FolderRefPrefix + f.ID.String()
	if err := s.CanAttachFolder(ctx, other, ref); err == nil {
		t.Fatal("only its owner attaches it")
	}
	att, err := s.FolderAttachment(ctx, owner, ref)
	if err != nil || att.Mime != "inode/directory" || !strings.Contains(att.Content, "oct.csv") ||
		!strings.Contains(att.Content, "read only") || !strings.Contains(att.Content, "untrusted_data") {
		t.Fatalf("the agent sees what it is and holds: %+v %v", att, err)
	}
	meta, err := s.FolderMeta(ctx, ref)
	if err != nil || meta["kind"] != "folder" || meta["name"] != "invoices" {
		t.Fatalf("%+v %v", meta, err)
	}
	if _, err := s.SetFolder(ctx, owner, f.ID.String(), "", false); err != nil {
		t.Fatal(err)
	}
	if err := s.CanAttachFolder(ctx, owner, ref); err == nil {
		t.Fatal("a folder no longer shared is not attached")
	}
}
