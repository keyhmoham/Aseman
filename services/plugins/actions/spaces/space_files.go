package spaces

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// projectFileKey is where a project's file is stored: under the project, so
// everything of a project is one folder in the object store.
func projectFileKey(space, file identity.ID) string {
	if space.IsZero() {
		return file.String()
	}
	return "projects/" + space.String() + "/" + file.String()
}

// deleteStoredFile removes a file's bytes and its record. A file whose bytes
// are already gone is still removed from the records.
func (s *Service) deleteStoredFile(ctx context.Context, f *filedata.File) error {
	if fs := s.K.FS(); fs != nil && f.StorageKey != "" {
		if err := fs.Delete(ctx, f.StorageKey); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
			return err
		}
	}
	return s.R.Delete(ctx, "files", f.ID)
}

// deleteSpaceFiles deletes every file uploaded into a project (attachments and
// the files its agents sent), bytes and records, when the project is deleted.
func (s *Service) deleteSpaceFiles(ctx context.Context, spaceID identity.ID) {
	var files []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &files); err != nil {
		s.L.Warn("could not list a deleted project's files", "space", spaceID.String(), "error", err)
		return
	}
	for i := range files {
		if err := s.deleteStoredFile(ctx, &files[i]); err != nil {
			s.L.Warn("could not delete a deleted project's file", "space", spaceID.String(), "file", files[i].ID.String(), "error", err)
		}
	}
}

// sweepOrphanFiles deletes files of projects that no longer exist: what was
// left behind by projects deleted before their files went with them. A project
// counts as gone only when the node says so; any other failure leaves the file.
func (s *Service) sweepOrphanFiles(ctx context.Context) {
	var files []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{}, &files); err != nil {
		return
	}
	gone := map[identity.ID]bool{}
	removed := 0
	for i := range files {
		f := &files[i]
		if f.SpaceID.IsZero() {
			continue
		}
		missing, known := gone[f.SpaceID]
		if !known {
			_, err := s.GetSpace(ctx, f.SpaceID)
			missing = err != nil && errs.CodeOf(err) == errs.CodeNotFound
			gone[f.SpaceID] = missing
		}
		if !missing {
			continue
		}
		if err := s.deleteStoredFile(ctx, f); err == nil {
			removed++
		}
	}
	if removed > 0 {
		s.L.Info("deleted files of projects that no longer exist", "files", removed)
	}
}
