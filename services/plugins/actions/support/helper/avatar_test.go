package helper

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func TestAvatarFileMakesTheCallersPicturePublic(t *testing.T) {
	ctx := context.Background()
	db := memory.New(logger.Global())
	for _, model := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, model); err != nil {
			t.Fatal(err)
		}
	}
	r := &repo.Repo{DB: db}
	me := identity.ID{Node: 1, Entity: 1}
	other := identity.ID{Node: 1, Entity: 2}
	put := func(entityID identity.EntityID, owner identity.ID, mime string, public bool) identity.ID {
		id := identity.ID{Node: 1, Entity: entityID}
		f := &filedata.File{Entity: entity.Entity{ID: id}, OwnerID: owner, Name: "a", Mime: mime, Public: public}
		if err := r.CreateID(ctx, "files", id, f); err != nil {
			t.Fatal(err)
		}
		return id
	}
	mine := put(10, me, "image/png", false)
	theirs := put(11, other, "image/png", false)
	shared := put(12, other, "image/jpeg", true)
	text := put(13, me, "text/plain", false)

	got, err := AvatarFile(ctx, r, me, "/v1/files/"+mine.String()+"/content")
	if err != nil || got != mine.String() {
		t.Fatalf("own picture = %q, %v", got, err)
	}
	var f filedata.File
	if err := r.Get(ctx, "files", mine, &f); err != nil || !f.Public {
		t.Fatalf("an avatar must become public: %+v %v", f, err)
	}
	if got, err := AvatarFile(ctx, r, me, shared.String()); err != nil || got != shared.String() {
		t.Fatalf("public picture = %q, %v", got, err)
	}
	if _, err := AvatarFile(ctx, r, me, theirs.String()); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("somebody else's private file: %v", err)
	}
	if _, err := AvatarFile(ctx, r, me, text.String()); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("a non-image: %v", err)
	}
	if got, err := AvatarFile(ctx, r, me, "  "); err != nil || got != "" {
		t.Fatalf("clearing = %q, %v", got, err)
	}
}

func TestTreeAvatarPrefersTheProfile(t *testing.T) {
	tree := map[string]any{"profile": map[string]any{"avatar": " p "}, "descriptor": map[string]any{"avatar": "d"}}
	if got := TreeAvatar(tree); got != "p" {
		t.Fatalf("got %q", got)
	}
	tree["profile"] = map[string]any{"avatar": ""}
	if got := TreeAvatar(tree); got != "d" {
		t.Fatalf("descriptor fallback, got %q", got)
	}
	if got := TreeAvatar(map[string]any{}); got != "" {
		t.Fatalf("got %q", got)
	}
}
