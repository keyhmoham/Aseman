// Package mysql implements the database port on MySQL via the shared SQL
// engine. It shares all semantics with the postgres adapter.
package mysql

import (
	"context"
	"database/sql"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/database/sqlcommon"

	_ "github.com/go-sql-driver/mysql"
)

// Adapter is the MySQL database plugin.
type Adapter struct {
	base.Base
	db     *sql.DB
	engine *sqlcommon.Engine
	cfg    database.Config
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "mysql",
			Category:    api.CategoryDatabase,
			Version:     "1.0.0",
			Description: "MySQL provider via the shared SQL engine",
			Provides:    []string{"database"},
			Log:         log,
		},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	a.cfg = cfg.Database(deps.Config)
	if a.cfg.DSN == "" {
		return errs.InvalidArgument("mysql adapter requires config.dsn (user:pass@tcp(host:3306)/db)")
	}
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return a.Open(ctx, a.cfg) }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements database.Database.
func (a *Adapter) Name() string { return "mysql" }

// Open implements database.Database.
func (a *Adapter) Open(ctx context.Context, c database.Config) error {
	db, err := sql.Open("mysql", c.DSN)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "open mysql")
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return errs.Wrap(errs.CodePlugin, err, "ping mysql")
	}
	a.db = db
	a.engine = sqlcommon.NewEngine(sqlcommon.MySQL(), db, a.Log)
	return nil
}

// Close implements database.Database.
func (a *Adapter) Close(ctx context.Context) error {
	if a.db != nil {
		return a.db.Close()
	}
	return nil
}

// Health implements database.Database.
func (a *Adapter) Health(ctx context.Context) database.Health {
	if a.db == nil {
		return database.Health{OK: false, Message: "mysql not open"}
	}
	if err := a.db.PingContext(ctx); err != nil {
		return database.Health{OK: false, Message: err.Error()}
	}
	return database.Health{OK: true, Message: "mysql healthy"}
}

// Transaction implements database.Database.
func (a *Adapter) Transaction(ctx context.Context, fn func(ctx context.Context, tx database.Tx) error) error {
	if a.db == nil {
		return errs.New(errs.CodeUnavailable, "mysql not open")
	}
	sqlTx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "begin tx")
	}
	tx := &txAdapter{tx: sqlTx, engine: a.engine}
	if err := fn(ctx, tx); err != nil {
		_ = sqlTx.Rollback()
		return err
	}
	if err := sqlTx.Commit(); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "commit tx")
	}
	return nil
}

type txAdapter struct {
	tx     *sql.Tx
	engine *sqlcommon.Engine
}

func (t *txAdapter) Create(ctx context.Context, model, id string, v any) error {
	return t.engine.CreateTx(ctx, t.tx, model, id, v)
}
func (t *txAdapter) Get(ctx context.Context, model, id string, out any) error {
	return t.engine.GetTx(ctx, t.tx, model, id, out)
}
func (t *txAdapter) Update(ctx context.Context, model, id string, v any) error {
	return t.engine.UpdateTx(ctx, t.tx, model, id, v)
}
func (t *txAdapter) Delete(ctx context.Context, model, id string) error {
	return t.engine.DeleteTx(ctx, t.tx, model, id)
}
func (t *txAdapter) Commit(ctx context.Context) error   { return t.tx.Commit() }
func (t *txAdapter) Rollback(ctx context.Context) error { return t.tx.Rollback() }

func (a *Adapter) RegisterModel(ctx context.Context, m database.Model) error {
	return a.engine.RegisterModel(ctx, m)
}
func (a *Adapter) UnregisterModel(ctx context.Context, name string) error {
	return a.engine.UnregisterModel(ctx, name)
}
func (a *Adapter) Models() []database.Model { return a.engine.Models() }
func (a *Adapter) Create(ctx context.Context, model, id string, v any) error {
	return a.engine.Create(ctx, model, id, v)
}
func (a *Adapter) Get(ctx context.Context, model, id string, out any) error {
	return a.engine.Get(ctx, model, id, out)
}
func (a *Adapter) Update(ctx context.Context, model, id string, v any) error {
	return a.engine.Update(ctx, model, id, v)
}
func (a *Adapter) Delete(ctx context.Context, model, id string) error {
	return a.engine.Delete(ctx, model, id)
}
func (a *Adapter) List(ctx context.Context, model string, f database.Filter, out any) error {
	return a.engine.List(ctx, model, f, out)
}
func (a *Adapter) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	return a.engine.Count(ctx, model, f)
}
func (a *Adapter) Query(ctx context.Context, model string, q database.Query, out any) error {
	return a.engine.Query(ctx, model, q, out)
}
func (a *Adapter) FieldNames(model string) ([]string, error) { return a.engine.FieldNames(model) }
func (a *Adapter) KindOf(model, field string) (database.Kind, error) {
	return a.engine.KindOf(model, field)
}

func (a *Adapter) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	return a.engine.CompareAndSwap(ctx, model, id, expected, value)
}

// Compile-time checks keep interchangeable providers on the same contracts.
var _ database.Database = (*Adapter)(nil)
var _ database.AtomicUpdater = (*Adapter)(nil)
