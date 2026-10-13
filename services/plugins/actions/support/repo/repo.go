// Package repo provides typed conveniences over the database port used by the
// application services.
package repo

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	dbbridge "github.com/tradera/tradera/plugins/adapters/database/bridge"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Repo wraps a database adapter.
type Repo struct {
	DB database.Database
}

// Create inserts a record under a fresh entity id.
func (r *Repo) Create(ctx context.Context, node identity.NodeID, model string, v any) (identity.ID, error) {
	id, err := identity.New(node)
	if err != nil {
		return identity.ID{}, err
	}
	if err := r.DB.Create(ctx, model, id.String(), v); err != nil {
		return identity.ID{}, err
	}
	return id, nil
}

// CreateID inserts a record under an explicit id.
func (r *Repo) CreateID(ctx context.Context, model string, id identity.ID, v any) error {
	return r.DB.Create(ctx, model, id.String(), v)
}

// Get reads a record by universal id.
func (r *Repo) Get(ctx context.Context, model string, id identity.ID, out any) error {
	return r.DB.Get(ctx, model, id.String(), out)
}

// GetString reads a record by universal id string.
func (r *Repo) GetString(ctx context.Context, model, id string, out any) error {
	return r.DB.Get(ctx, model, id, out)
}

// Update replaces a record.
func (r *Repo) Update(ctx context.Context, model string, id identity.ID, v any) error {
	return r.DB.Update(ctx, model, id.String(), v)
}

// UpdateString replaces a record by id string.
func (r *Repo) UpdateString(ctx context.Context, model, id string, v any) error {
	return r.DB.Update(ctx, model, id, v)
}

// Delete removes a record.
func (r *Repo) Delete(ctx context.Context, model string, id identity.ID) error {
	return r.DB.Delete(ctx, model, id.String())
}

// EnsureCreated inserts, ignoring AlreadyExists (idempotent bootstrap).
func (r *Repo) EnsureCreated(ctx context.Context, model string, id identity.ID, v any) error {
	// Avoid deliberately issuing a duplicate INSERT during every bootstrap.
	// PostgreSQL logs constraint violations even when the caller correctly
	// treats AlreadyExists as success, which made healthy restarts look broken.
	count, err := r.DB.Count(ctx, model, database.Filter{
		Equal: map[string]any{"id": id.String()},
	})
	if err != nil {
		return err
	}
	if count > 0 {
		return nil
	}
	err = r.DB.Create(ctx, model, id.String(), v)
	if errs.CodeOf(err) == errs.CodeAlreadyExists {
		return nil
	}
	return err
}

// List reads records by filter into out (*[]T).
func (r *Repo) List(ctx context.Context, model string, f database.Filter, out any) error {
	return r.DB.List(ctx, model, f, out)
}

// Count counts records by filter.
func (r *Repo) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	return r.DB.Count(ctx, model, f)
}

// RequireAtomicUpdates validates the provider capability used by durable claims
// and optimistic writes. An unsafe read/update emulation is not used.
func (r *Repo) RequireAtomicUpdates() error {
	if support, ok := r.DB.(database.AtomicUpdateSupport); ok && !support.SupportsAtomicUpdates() {
		return errs.New(errs.CodeUnavailable, "database provider does not support atomic conditional updates")
	}
	if _, ok := r.DB.(database.AtomicUpdater); !ok {
		return errs.New(errs.CodeUnavailable, "database provider does not support atomic conditional updates")
	}
	return nil
}

// CompareAndSwap performs a provider-neutral conditional replacement.
func (r *Repo) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	updater, ok := r.DB.(database.AtomicUpdater)
	if !ok {
		return false, r.RequireAtomicUpdates()
	}
	return updater.CompareAndSwap(ctx, model, id, expected, value)
}

func New(k api.Kernel) *Repo { return &Repo{DB: dbbridge.Database(k)} }
