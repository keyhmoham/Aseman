// Package memory implements the database port with an in-memory engine. It is
// the default engine (zero-configuration) and the reference implementation of
// the generic filter/schema semantics that the SQL and NoSQL adapters mirror.
package memory

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Adapter is an in-memory database plugin.
type Adapter struct {
	base.Base
	mu     sync.RWMutex
	models map[string]database.Model
	// tables: model name -> id -> row(map field->value)
	tables map[string]map[string]map[string]any
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "memory",
			Category:    api.CategoryDatabase,
			Version:     "1.0.0",
			Description: "In-memory database engine (default, zero-config)",
			Provides:    []string{"database"},
			Log:         log,
		},
		models: map[string]database.Model{},
		tables: map[string]map[string]map[string]any{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return nil }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return nil }

// Name implements database.Database.
func (a *Adapter) Name() string { return "memory" }

// Open implements database.Database (no-op for memory).
func (a *Adapter) Open(ctx context.Context, cfg database.Config) error { return nil }

// Close implements database.Database.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements database.Database.
func (a *Adapter) Health(ctx context.Context) database.Health {
	return database.Health{OK: true, Message: "memory engine healthy"}
}

// RegisterModel implements database.Database.
func (a *Adapter) RegisterModel(ctx context.Context, m database.Model) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.models[m.Name] = m
	if a.tables[m.Name] == nil {
		a.tables[m.Name] = map[string]map[string]any{}
	}
	return nil
}

// UnregisterModel implements database.Database.
func (a *Adapter) UnregisterModel(ctx context.Context, name string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.models, name)
	delete(a.tables, name)
	return nil
}

// Models implements database.Database.
func (a *Adapter) Models() []database.Model {
	a.mu.RLock()
	defer a.mu.RUnlock()
	out := make([]database.Model, 0, len(a.models))
	for _, m := range a.models {
		out = append(out, m)
	}
	return out
}

func (a *Adapter) model(name string) (database.Model, error) {
	m, ok := a.models[name]
	if !ok {
		return database.Model{}, errs.NotFound("model " + name)
	}
	return m, nil
}

// Create implements database.Database.
func (a *Adapter) Create(ctx context.Context, model, id string, v any) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.create(model, id, v, nil)
}

// Get implements database.Database.
func (a *Adapter) Get(ctx context.Context, model, id string, out any) error {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.get(model, id, out)
}

// Update implements database.Database.
func (a *Adapter) Update(ctx context.Context, model, id string, v any) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.update(model, id, v, nil)
}

// Delete implements database.Database.
func (a *Adapter) Delete(ctx context.Context, model, id string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.delete(model, id, nil)
}

// The lowercase operations assume the caller holds the lock. Writes record how
// to revert themselves in undo (when non-nil) so a failed transaction can roll
// back.

func (a *Adapter) create(model, id string, v any, undo *[]func()) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	row["id"] = id
	if _, exists := a.tables[model][id]; exists {
		return errs.AlreadyExists("record " + id + " in " + model)
	}
	a.tables[model][id] = row
	if undo != nil {
		*undo = append(*undo, func() { delete(a.tables[model], id) })
	}
	return nil
}

func (a *Adapter) get(model, id string, out any) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	row, ok := a.tables[model][id]
	if !ok {
		return errs.NotFound("record " + id + " in " + model)
	}
	return database.Encode(m, row, out)
}

func (a *Adapter) update(model, id string, v any, undo *[]func()) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	old, ok := a.tables[model][id]
	if !ok {
		return errs.NotFound("record " + id + " in " + model)
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	row["id"] = id
	a.tables[model][id] = row
	if undo != nil {
		*undo = append(*undo, func() { a.tables[model][id] = old })
	}
	return nil
}

func (a *Adapter) delete(model, id string, undo *[]func()) error {
	old, ok := a.tables[model][id]
	if !ok {
		return errs.NotFound("record " + id + " in " + model)
	}
	delete(a.tables[model], id)
	if undo != nil {
		*undo = append(*undo, func() { a.tables[model][id] = old })
	}
	return nil
}

// List implements database.Database.
func (a *Adapter) List(ctx context.Context, model string, f database.Filter, out any) error {
	a.mu.RLock()
	defer a.mu.RUnlock()
	m, err := a.model(model)
	if err != nil {
		return err
	}
	matched := make([]map[string]any, 0, len(a.tables[model]))
	for _, row := range a.tables[model] {
		if matches(row, f) {
			matched = append(matched, row)
		}
	}
	if f.OrderBy != "" {
		sort.SliceStable(matched, func(i, j int) bool {
			less := compare(matched[i][f.OrderBy], matched[j][f.OrderBy])
			if !f.Asc {
				less = !less
			}
			return less
		})
	}
	start := f.Offset
	if start > len(matched) {
		start = len(matched)
	}
	end := len(matched)
	if f.Limit > 0 && start+f.Limit < end {
		end = start + f.Limit
	}
	page := matched[start:end]
	return decodeList(m, page, out)
}

// Count implements database.Database.
func (a *Adapter) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if _, ok := a.tables[model]; !ok {
		return 0, errs.NotFound("model " + model)
	}
	var n int64
	for _, row := range a.tables[model] {
		if matches(row, f) {
			n++
		}
	}
	return n, nil
}

// Transaction implements database.Database. Transactions are serialized by the
// adapter lock, which the transaction's operations therefore must not retake;
// a failed transaction reverts every write it made.
func (a *Adapter) Transaction(ctx context.Context, fn func(ctx context.Context, tx database.Tx) error) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	t := &tx{adapter: a}
	if err := fn(ctx, t); err != nil {
		t.rollback()
		return err
	}
	return nil
}

// Query implements database.Database. Native queries are not supported by the
// memory engine; only an exact-key lookup via Meta is honoured.
func (a *Adapter) Query(ctx context.Context, model string, q database.Query, out any) error {
	return errs.New(errs.CodeUnavailable, "native queries not supported by memory engine")
}

// FieldNames implements database.Database.
func (a *Adapter) FieldNames(model string) ([]string, error) {
	m, err := a.model(model)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(m.Fields))
	for _, f := range m.Fields {
		names = append(names, f.Name)
	}
	return names, nil
}

// KindOf implements database.Database.
func (a *Adapter) KindOf(model, field string) (database.Kind, error) {
	m, err := a.model(model)
	if err != nil {
		return 0, err
	}
	f, ok := m.Field(field)
	if !ok {
		return 0, errs.NotFound("field " + field + " in model " + model)
	}
	return f.Kind, nil
}

func matches(row map[string]any, f database.Filter) bool {
	for k, v := range f.Equal {
		if !eq(row[k], v) {
			return false
		}
	}
	for k, vs := range f.In {
		found := false
		for _, v := range vs {
			if eq(row[k], v) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	for k, v := range f.GreaterThan {
		if !cmpNum(row[k], v, 1) {
			return false
		}
	}
	for k, v := range f.LessThan {
		if !cmpNum(row[k], v, -1) {
			return false
		}
	}
	return true
}

func eq(a, b any) bool {
	if an, ok := numOf(a); ok {
		if bn, ok2 := numOf(b); ok2 {
			return an == bn
		}
	}
	if as, ok := strOf(a); ok {
		if bs, ok2 := strOf(b); ok2 {
			return as == bs
		}
	}
	return a == b
}

// strOf returns the string form of any string-like value (plain or named
// string types and byte slices), which is how the database port stores string
// columns.
func strOf(v any) (string, bool) {
	switch t := v.(type) {
	case string:
		return t, true
	case []byte:
		return string(t), true
	default:
		rv := reflect.ValueOf(v)
		if rv.IsValid() && rv.Kind() == reflect.String {
			return rv.String(), true
		}
		return "", false
	}
}

func numOf(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case int64:
		return float64(t), true
	case int:
		return float64(t), true
	default:
		return 0, false
	}
}

// cmpNum applies a range filter with the same ordering the adapter sorts by
// (numbers, times, strings), so a time cursor filters like it would in SQL.
func cmpNum(a, b any, dir int) bool {
	if dir > 0 {
		return less(b, a)
	}
	return less(a, b)
}

func compare(a, b any) bool {
	return less(a, b)
}

func less(a, b any) bool {
	an, ok1 := numOf(a)
	bn, ok2 := numOf(b)
	if ok1 && ok2 {
		return an < bn
	}
	at, ok1 := a.(time.Time)
	bt, ok2 := b.(time.Time)
	if ok1 && ok2 {
		return at.Before(bt)
	}
	as, ok1 := a.(string)
	bs, ok2 := b.(string)
	if ok1 && ok2 {
		return as < bs
	}
	return false
}

func decodeList(m database.Model, rows []map[string]any, out any) error {
	return database.DecodeList(m, rows, out)
}

type tx struct {
	adapter *Adapter
	undo    []func()
}

func (t *tx) Create(ctx context.Context, model, id string, v any) error {
	return t.adapter.create(model, id, v, &t.undo)
}
func (t *tx) Get(ctx context.Context, model, id string, out any) error {
	return t.adapter.get(model, id, out)
}
func (t *tx) Update(ctx context.Context, model, id string, v any) error {
	return t.adapter.update(model, id, v, &t.undo)
}
func (t *tx) Delete(ctx context.Context, model, id string) error {
	return t.adapter.delete(model, id, &t.undo)
}
func (t *tx) Commit(ctx context.Context) error { t.undo = nil; return nil }
func (t *tx) Rollback(ctx context.Context) error {
	t.rollback()
	return nil
}
func (t *tx) rollback() {
	for i := len(t.undo) - 1; i >= 0; i-- {
		t.undo[i]()
	}
	t.undo = nil
}

func (a *Adapter) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	m, err := a.model(model)
	if err != nil {
		return false, err
	}
	for key := range expected {
		if _, ok := m.Field(key); !ok {
			return false, errs.InvalidArgument("unknown condition field")
		}
	}
	current, ok := a.tables[model][id]
	if !ok {
		return false, nil
	}
	for key, want := range expected {
		if fmt.Sprint(current[key]) != fmt.Sprint(want) {
			return false, nil
		}
	}
	row, err := database.Decode(m, value)
	if err != nil {
		return false, err
	}
	row["id"] = id
	a.tables[model][id] = row
	return true, nil
}

// Compile-time checks keep interchangeable providers on the same contracts.
var _ database.Database = (*Adapter)(nil)
var _ database.AtomicUpdater = (*Adapter)(nil)
