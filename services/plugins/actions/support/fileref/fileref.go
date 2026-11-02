// Package fileref decides when a stored file's bytes may go. Two file records
// can point at the same bytes (a person who keeps a file someone sent them has
// their own record for it, not a second copy), so deleting a record deletes the
// bytes only when it was the last one.
package fileref

import (
	"context"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Store is the part of the file store Release needs.
type Store interface {
	Delete(ctx context.Context, key string) error
}

// Release deletes the bytes stored under key unless a file record still uses
// them. Call it AFTER the record was deleted, so the record being removed does
// not count; if the lookup fails the bytes are kept (a leak is better than
// losing someone's file).
func Release(ctx context.Context, r *repo.Repo, fs Store, key string) error {
	if fs == nil || key == "" {
		return nil
	}
	var users []struct {
		ID string `db:"id"`
	}
	if err := r.List(ctx, "files", database.Filter{Equal: map[string]any{"storage_key": key}, Limit: 1}, &users); err != nil {
		return err
	}
	if len(users) > 0 {
		return nil
	}
	if err := fs.Delete(ctx, key); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return err
	}
	return nil
}
