package bridge

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Repository resolves the active database for each operation. Transactions
// remain bound to the provider selected when the transaction begins.
func Database(k api.Kernel) database.Database { return &currentDatabase{k: k} }

type currentDatabase struct{ k api.Kernel }

var _ database.Database = (*currentDatabase)(nil)

func (p *currentDatabase) Name() string {
	db := p.k.DB()
	if db == nil {
		return "unavailable"
	}
	return db.Name()
}
func (p *currentDatabase) Open(ctx context.Context, cfg database.Config) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Open(ctx, cfg)
}
func (p *currentDatabase) Close(ctx context.Context) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Close(ctx)
}
func (p *currentDatabase) Health(ctx context.Context) database.Health {
	db := p.k.DB()
	if db == nil {
		return database.Health{OK: false, Message: "database adapter unavailable"}
	}
	return db.Health(ctx)
}
func (p *currentDatabase) RegisterModel(ctx context.Context, m database.Model) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.RegisterModel(ctx, m)
}
func (p *currentDatabase) UnregisterModel(ctx context.Context, name string) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.UnregisterModel(ctx, name)
}
func (p *currentDatabase) Models() []database.Model {
	db := p.k.DB()
	if db == nil {
		return nil
	}
	return db.Models()
}
func (p *currentDatabase) Create(ctx context.Context, model, id string, v any) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Create(ctx, model, id, v)
}
func (p *currentDatabase) Get(ctx context.Context, model, id string, out any) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Get(ctx, model, id, out)
}
func (p *currentDatabase) Update(ctx context.Context, model, id string, v any) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Update(ctx, model, id, v)
}
func (p *currentDatabase) Delete(ctx context.Context, model, id string) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Delete(ctx, model, id)
}
func (p *currentDatabase) List(ctx context.Context, model string, f database.Filter, out any) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.List(ctx, model, f, out)
}
func (p *currentDatabase) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	db := p.k.DB()
	if db == nil {
		return 0, errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Count(ctx, model, f)
}
func (p *currentDatabase) Transaction(ctx context.Context, fn func(ctx context.Context, tx database.Tx) error) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Transaction(ctx, fn)
}
func (p *currentDatabase) Query(ctx context.Context, model string, q database.Query, out any) error {
	db := p.k.DB()
	if db == nil {
		return errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.Query(ctx, model, q, out)
}
func (p *currentDatabase) FieldNames(model string) ([]string, error) {
	db := p.k.DB()
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.FieldNames(model)
}
func (p *currentDatabase) KindOf(model, field string) (database.Kind, error) {
	db := p.k.DB()
	if db == nil {
		return 0, errs.New(errs.CodeUnavailable, "database adapter unavailable")
	}
	return db.KindOf(model, field)
}
func (p *currentDatabase) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	db, ok := p.k.DB().(database.AtomicUpdater)
	if !ok {
		return false, errs.New(errs.CodeUnavailable, "database provider does not support atomic conditional updates")
	}
	return db.CompareAndSwap(ctx, model, id, expected, value)
}

func (p *currentDatabase) SupportsAtomicUpdates() bool {
	db := p.k.DB()
	if support, ok := db.(database.AtomicUpdateSupport); ok {
		return support.SupportsAtomicUpdates()
	}
	_, ok := db.(database.AtomicUpdater)
	return ok
}
