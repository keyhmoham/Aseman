package spaces

import (
	"context"
	"encoding/base64"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	fslocal "github.com/tradera/tradera/plugins/adapters/filesystem/local"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"github.com/tradera/tradera/plugins/config"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func fileToolHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	tmp := t.TempDir()
	cfg := &dconfig.Config{Plugins: dconfig.PluginsConfig{
		Adapters: []dconfig.PluginSpec{{Name: "local", Config: map[string]any{"base_path": tmp}}},
	}}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Config: dconfig.NewProvider(cfg)})
	if err := k.Register(fslocal.New(logger.Global())); err != nil {
		t.Fatal(err)
	}
	if err := k.Boot(ctx, []string{"local"}); err != nil {
		t.Fatal(err)
	}
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.Bots = bots.NewService(k, s.R, logger.Global())
	return s, ctx
}

// addDevBotMember creates a "dev" langchain agent bot and joins it to the space.
func addDevBotMember(t *testing.T, s *Service, ctx context.Context, spaceID identity.ID) identity.ID {
	t.Helper()
	now := time.Now().UTC()
	accID, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.R.CreateID(ctx, "accounts", accID, &account.Account{
		Entity: entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindBot, Handle: "dev", Status: account.StatusActive, MetadataID: accID,
	}); err != nil {
		t.Fatal(err)
	}
	botID, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.R.CreateID(ctx, "bots", botID, &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: accID, AccountID: accID, Name: "dev", Kind: bot.KindAgent,
		VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning, VMID: "dev",
	}); err != nil {
		t.Fatal(err)
	}
	memID, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, MemberID: accID, Role: membership.RoleBot, JoinedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	return accID
}

func TestFileSendToolUploadsAndPostsAttachment(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	devAcc := addDevBotMember(t, s, ctx, sp.ID)

	content := base64.StdEncoding.EncodeToString([]byte("fake-png-bytes"))
	out, err := s.fileSendTool(ctx, sp.ID, "dev", "file_send",
		`{"content":"`+content+`","name":"chart.png","mime":"image/png","caption":"Here is a chart"}`)
	if err != nil {
		t.Fatal(err)
	}
	if out == "" {
		t.Fatal("expected a result")
	}

	// The file was uploaded, owned by the dev agent.
	var files []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String(), "name": "chart.png"},
	}, &files); err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].OwnerID != devAcc {
		t.Fatalf("expected one file owned by dev, got %+v", files)
	}

	// A chat message from the dev agent carries the attachment + caption.
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String(), "sender_id": devAcc.String()},
	}, &msgs); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, m := range msgs {
		atts := m.ParseAttachments()
		if m.Body == "Here is a chart" && len(atts) == 1 && atts[0] == files[0].ID.String() {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected an attachment message from dev, got %+v", msgs)
	}
}

func TestFileSendToolRejectsNoData(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	addDevBotMember(t, s, ctx, sp.ID)
	if _, err := s.fileSendTool(ctx, sp.ID, "dev", "file_send", `{}`); err == nil {
		t.Fatal("expected error for missing data")
	}
}
func TestToolDispatchGatesMultimodalGeneration(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	addDevBotMember(t, s, ctx, sp.ID)

	// Without media intent, image generation and file sending are hard-gated.
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "image_generate", `{"prompt":"a sunset"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("image_generate must be gated without media intent, got %v", err)
	}
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "file_send", `{"content":"ZmFrZQ==","name":"x.png","mime":"image/png"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("file_send must be gated without media intent, got %v", err)
	}
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "file_upload", `{"content":"ZmFrZQ==","name":"x.png"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("file_upload must be gated without media intent, got %v", err)
	}

	// With explicit media intent the gate passes: image_generate then fails for
	// a missing image model (not for the gate), proving it got through.
	mctx := vmm.WithMediaIntent(ctx, true)
	if _, err := s.ToolDispatch(mctx, sp.ID.String(), "dev", "image_generate", `{"prompt":"a sunset"}`); errs.CodeOf(err) == errs.CodePermission {
		t.Fatalf("image_generate should pass the gate with media intent, got %v", err)
	}
	// file_send with media intent succeeds end to end.
	if out, err := s.ToolDispatch(mctx, sp.ID.String(), "dev", "file_send", `{"content":"ZmFrZQ==","name":"x.png","mime":"image/png","caption":"here"}`); err != nil || out == "" {
		t.Fatalf("file_send with media intent should succeed, got %v %q", err, out)
	}
}

func TestRequestedWebsiteCanBeDeliveredWithoutGrantingImages(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "website intent", "")
	if err != nil {
		t.Fatal(err)
	}
	addDevBotMember(t, s, ctx, sp.ID)
	ctx = vmm.WithRequestIntent(ctx, "create a landing page about web3 and serve it", nil)
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "file_send", `{"content":"PGh0bWw+PC9odG1sPg==","name":"index.html","mime":"text/html"}`); err != nil {
		t.Fatalf("requested source delivery: %v", err)
	}
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "image_generate", `{"prompt":"a sunset"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("unsolicited image generation: %v", err)
	}
	ctx = vmm.WithExecution(ctx, vmm.Execution{Capabilities: []string{}})
	if _, err := s.ToolDispatch(ctx, sp.ID.String(), "dev", "file_send", `{"content":"PGh0bWw+PC9odG1sPg==","name":"index.html"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("intent bypassed capabilities: %v", err)
	}
}

func testWorkerRoom(t *testing.T, s *Service, ctx context.Context, spaceID identity.ID, name string) identity.ID {
	t.Helper()
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	room := &space.Room{Entity: entity.Entity{ID: id}, SpaceID: spaceID, Name: name}
	if err := s.R.CreateID(ctx, "rooms", id, room); err != nil {
		t.Fatal(err)
	}
	return id
}
