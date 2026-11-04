package runtime

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/lifetime"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

type guardedDatabase struct {
	remember func(database.Model)
	forget   func(string)
	port     database.Database
	gate     *lifetime.Gate
}

func (p *guardedDatabase) Name() string {
	var zero0 string
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.Name()
}
func (p *guardedDatabase) Open(ctx context.Context, cfg database.Config) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Open(ctx, cfg)
}
func (p *guardedDatabase) Close(ctx context.Context) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Close(ctx)
}
func (p *guardedDatabase) Health(ctx context.Context) database.Health {
	var zero0 database.Health
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0
	}
	defer release()
	ctx = operationCtx
	return p.port.Health(ctx)
}
func (p *guardedDatabase) RegisterModel(ctx context.Context, m database.Model) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	if err := p.port.RegisterModel(ctx, m); err != nil {
		return err
	}
	p.remember(m)
	return nil
}
func (p *guardedDatabase) UnregisterModel(ctx context.Context, name string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	if err := p.port.UnregisterModel(ctx, name); err != nil {
		return err
	}
	p.forget(name)
	return nil
}
func (p *guardedDatabase) Models() []database.Model {
	var zero0 []database.Model
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.Models()
}
func (p *guardedDatabase) Create(ctx context.Context, model string, id string, v any) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Create(ctx, model, id, v)
}
func (p *guardedDatabase) Get(ctx context.Context, model string, id string, out any) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Get(ctx, model, id, out)
}
func (p *guardedDatabase) Update(ctx context.Context, model string, id string, v any) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Update(ctx, model, id, v)
}
func (p *guardedDatabase) Delete(ctx context.Context, model string, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Delete(ctx, model, id)
}
func (p *guardedDatabase) List(ctx context.Context, model string, f database.Filter, out any) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.List(ctx, model, f, out)
}
func (p *guardedDatabase) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	var zero0 int64
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Count(ctx, model, f)
}
func (p *guardedDatabase) Transaction(ctx context.Context, fn func(ctx context.Context, tx database.Tx) error) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Transaction(ctx, fn)
}
func (p *guardedDatabase) Query(ctx context.Context, model string, q database.Query, out any) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Query(ctx, model, q, out)
}
func (p *guardedDatabase) FieldNames(model string) ([]string, error) {
	var zero0 []string
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0, err
	}
	defer release()
	_ = operationCtx
	return p.port.FieldNames(model)
}
func (p *guardedDatabase) KindOf(model string, field string) (database.Kind, error) {
	var zero0 database.Kind
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0, err
	}
	defer release()
	_ = operationCtx
	return p.port.KindOf(model, field)
}

func (p *guardedDatabase) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return false, err
	}
	defer release()
	port, ok := p.port.(database.AtomicUpdater)
	if !ok {
		return false, errs.New(errs.CodeUnavailable, "database provider does not support atomic conditional updates")
	}
	return port.CompareAndSwap(ctx, model, id, expected, value)
}

func (p *guardedDatabase) SupportsAtomicUpdates() bool {
	if support, ok := p.port.(database.AtomicUpdateSupport); ok && !support.SupportsAtomicUpdates() {
		return false
	}
	_, ok := p.port.(database.AtomicUpdater)
	return ok
}

func (p *guardedDatabase) vectorPort() (database.VectorIndex, error) {
	port, ok := p.port.(database.VectorIndex)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "database provider has no vector index")
	}
	return port, nil
}

func (p *guardedDatabase) VectorUpsert(ctx context.Context, collection, id, scope string, vector []float32) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, err := p.vectorPort()
	if err != nil {
		return err
	}
	return port.VectorUpsert(ctx, collection, id, scope, vector)
}

func (p *guardedDatabase) VectorDelete(ctx context.Context, collection, id string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, err := p.vectorPort()
	if err != nil {
		return err
	}
	return port.VectorDelete(ctx, collection, id)
}

func (p *guardedDatabase) VectorSearch(ctx context.Context, collection string, scopes []string, vector []float32, limit int) ([]database.VectorHit, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	port, err := p.vectorPort()
	if err != nil {
		return nil, err
	}
	return port.VectorSearch(ctx, collection, scopes, vector, limit)
}

func (p *guardedDatabase) SupportsVectorIndex() bool {
	if support, ok := p.port.(database.VectorIndexSupport); ok && !support.SupportsVectorIndex() {
		return false
	}
	_, ok := p.port.(database.VectorIndex)
	return ok
}

func Guard(port database.Database, gate *lifetime.Gate, remember func(database.Model), forget func(string)) database.Database {
	return &guardedDatabase{port: port, gate: gate, remember: remember, forget: forget}
}
