// Package metasvc implements the JSON-tree metadata service shared by accounts
// and spaces: partial add/update/delete patches, public/private path control
// and visibility-filtered reads.
package metasvc

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Service implements metadata operations.
type Service struct {
	K api.Kernel
	R *repo.Repo
}

// FindByOwner returns the metadata record of an owner by universal id.
func (s *Service) FindByOwner(ctx context.Context, owner identity.ID) (*metadata.Record, error) {
	var list []metadata.Record
	if err := s.R.List(ctx, "metadatas", database.Filter{Equal: map[string]any{"owner": owner.String()}}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("metadata for " + owner.String())
	}
	return &list[0], nil
}

// Get returns the metadata record.
func (s *Service) Get(ctx context.Context, owner identity.ID) (*metadata.Record, error) {
	return s.FindByOwner(ctx, owner)
}

// View returns metadata honoring visibility: owners see everything, others see
// only the public projection.
func (s *Service) View(ctx context.Context, viewer, owner identity.ID) (*metadata.Record, error) {
	rec, err := s.FindByOwner(ctx, owner)
	if err != nil {
		return nil, err
	}
	if viewer == owner {
		return rec, nil
	}
	view := *rec
	view.Tree = rec.PublicView()
	return &view, nil
}

// Patch applies partial ops to the owner's tree.
func (s *Service) Patch(ctx context.Context, owner identity.ID, p jsonpatch.Patch) error {
	rec, err := s.FindByOwner(ctx, owner)
	if err != nil {
		return err
	}
	if err := rec.ApplyPatch(p); err != nil {
		return err
	}
	rec.UpdatedAt = time.Now().UTC()
	return s.update(ctx, rec)
}

// ReplaceTree replaces the whole tree (full update).
func (s *Service) ReplaceTree(ctx context.Context, owner identity.ID, tree metadata.Tree) error {
	rec, err := s.FindByOwner(ctx, owner)
	if err != nil {
		return err
	}
	rec.Tree = tree
	rec.Version++
	rec.UpdatedAt = time.Now().UTC()
	return s.update(ctx, rec)
}

// SetPublicPaths sets the public path list.
func (s *Service) SetPublicPaths(ctx context.Context, owner identity.ID, paths []string) error {
	rec, err := s.FindByOwner(ctx, owner)
	if err != nil {
		return err
	}
	rec.SetPublicPaths(paths)
	rec.UpdatedAt = time.Now().UTC()
	return s.update(ctx, rec)
}

// LinkFile stores a file id at a metadata path.
func (s *Service) LinkFile(ctx context.Context, owner identity.ID, path string, fileID identity.ID) error {
	return s.Patch(ctx, owner, jsonpatch.Patch{{
		Op: "set", Path: path, Value: map[string]any{"file_id": fileID.String()},
	}})
}

func (s *Service) update(ctx context.Context, rec *metadata.Record) error {
	rec.ID = rec.Owner
	return s.R.UpdateString(ctx, "metadatas", rec.Owner, rec)
}
