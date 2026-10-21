package helper

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// AvatarFile checks a stored file chosen as an avatar (of a person, a
// workspace or a bot) and returns its id. An avatar is a picture shown to
// everyone who can see what it stands for, so a file the caller uploaded is
// made public; somebody else's file may only be used when it already is. An
// empty ref clears the avatar and returns "". A ref may be a bare id or the
// file's content path (/v1/files/{id}/content).
func AvatarFile(ctx context.Context, r *repo.Repo, caller identity.ID, ref string) (string, error) {
	ref = strings.TrimSpace(ref)
	ref = strings.TrimSuffix(strings.TrimPrefix(ref, "/v1/files/"), "/content")
	if ref == "" {
		return "", nil
	}
	id, err := identity.Parse(ref)
	if err != nil {
		return "", errs.InvalidArgument("avatar must be a stored file")
	}
	var file filedata.File
	if err := r.Get(ctx, "files", id, &file); err != nil {
		return "", err
	}
	if !strings.HasPrefix(strings.ToLower(file.Mime), "image/") {
		return "", errs.InvalidArgument("avatar must be an image")
	}
	if !file.Public {
		if file.OwnerID != caller {
			return "", errs.Permission("avatar file is not yours")
		}
		file.Public = true
		file.UpdatedAt = time.Now().UTC()
		if err := r.Update(ctx, "files", file.ID, &file); err != nil {
			return "", err
		}
	}
	return file.ID.String(), nil
}

// TreeAvatar reads the avatar recorded in a metadata tree: its profile's, or
// for a tool server without one, the icon in its descriptor.
func TreeAvatar(tree map[string]any) string {
	if p, ok := tree["profile"].(map[string]any); ok {
		if avatar, _ := p["avatar"].(string); strings.TrimSpace(avatar) != "" {
			return strings.TrimSpace(avatar)
		}
	}
	if d, ok := tree["descriptor"].(map[string]any); ok {
		if avatar, _ := d["avatar"].(string); strings.TrimSpace(avatar) != "" {
			return strings.TrimSpace(avatar)
		}
	}
	return ""
}
