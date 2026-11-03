// Package database defines the driven port that all database plugins (postgres,
// mysql, mongodb, in-memory, ...) must implement. It is deliberately provider
// agnostic: adapters map the generic model/record model to their own storage
// engine (relational tables or document collections).
package database

import (
	"context"
	"time"
)

// Kind describes the storage type of a model field.
type Kind int

const (
	KindString Kind = iota
	KindInt64
	KindFloat64
	KindBool
	KindJSON
	KindTime
	KindBytes
)

// Field describes a single persisted field of a model.
type Field struct {
	Name   string
	Kind   Kind
	PK     bool
	Index  bool
	Unique bool
}

// Model is a logical schema descriptor. Adapters map it onto a table or
// collection. The primary key is always the universal id string.
type Model struct {
	Name   string
	Table  string
	Fields []Field
}

// Field returns the descriptor of a field by name.
func (m Model) Field(name string) (Field, bool) {
	for _, f := range m.Fields {
		if f.Name == name {
			return f, true
		}
	}
	return Field{}, false
}

// Config is the provider specific configuration for a database plugin.
type Config struct {
	DSN     string            `json:"dsn"`
	Options map[string]string `json:"options,omitempty"`
}

// Filter is a minimal, cross-provider query filter. Drivers translate it into
// their native query language. Logical operators are AND-combined.
type Filter struct {
	// Equal maps field name -> exact value (string, int64, float64, bool).
	Equal map[string]any `json:"equal,omitempty"`
	// In maps field name -> list of values.
	In map[string][]any `json:"in,omitempty"`
	// GreaterThan / LessThan maps field name -> value.
	GreaterThan map[string]any `json:"gt,omitempty"`
	LessThan    map[string]any `json:"lt,omitempty"`
	// OrderBy field name and direction.
	OrderBy string `json:"order_by,omitempty"`
	Asc     bool   `json:"asc,omitempty"`
	// Limit / Offset for paging. Limit <= 0 means no limit.
	Limit  int `json:"limit,omitempty"`
	Offset int `json:"offset,omitempty"`
}

// Query is a free-form native query executed against one model. It is only
// guaranteed to work on the adapter it targets (used by admin tooling).
type Query struct {
	Raw   string         `json:"raw"`
	Args  []any          `json:"args,omitempty"`
	Limit int            `json:"limit,omitempty"`
	Meta  map[string]any `json:"meta,omitempty"`
}

// Iterator streams records of one model.
type Iterator interface {
	Next(out any) bool
	Err() error
	Close() error
}

// Tx is a transactional boundary.
type Tx interface {
	Create(ctx context.Context, model, id string, v any) error
	Get(ctx context.Context, model, id string, out any) error
	Update(ctx context.Context, model, id string, v any) error
	Delete(ctx context.Context, model, id string) error
	Commit(ctx context.Context) error
	Rollback(ctx context.Context) error
}

// Health reports adapter liveness with an optional diagnostic message.
type Health struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
	Latency string `json:"latency,omitempty"`
}

// Database is the driven port implemented by database plugins.
type Database interface {
	// Name returns the logical provider name, e.g. "postgres".
	Name() string
	Open(ctx context.Context, cfg Config) error
	Close(ctx context.Context) error
	Health(ctx context.Context) Health

	RegisterModel(ctx context.Context, m Model) error
	UnregisterModel(ctx context.Context, name string) error
	Models() []Model

	Create(ctx context.Context, model, id string, v any) error
	Get(ctx context.Context, model, id string, out any) error
	Update(ctx context.Context, model, id string, v any) error
	Delete(ctx context.Context, model, id string) error
	List(ctx context.Context, model string, f Filter, out any) error
	Count(ctx context.Context, model string, f Filter) (int64, error)

	Transaction(ctx context.Context, fn func(ctx context.Context, tx Tx) error) error
	Query(ctx context.Context, model string, q Query, out any) error

	// FieldNames returns the persisted field names of a model.
	FieldNames(model string) ([]string, error)
	// KindOf returns the storage kind of a model field.
	KindOf(model, field string) (Kind, error)
}

// WithTimeout is a small helper binding a timeout to an operation context.
func WithTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, d)
}

// AtomicUpdater is an optional provider-neutral capability for durable claims
// and optimistic writes. SQL and NoSQL adapters implement the same semantics:
// replace the existing record at id iff every expected scalar field matches;
// return false without error on a mismatch or missing record; reject unknown
// condition fields; match nil as a null/missing value; preserve the supplied id.
// The comparison and replacement must be one atomic operation across clients.
// Services access this through repo, never through a concrete adapter. Providers
// lacking the capability remain usable for basic CRUD; durable workflows and
// scheduling return an explicit capability error rather than an unsafe fallback.
type AtomicUpdater interface {
	CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error)
}

// AtomicUpdateSupport lets resolving/guarded ports report the current provider's
// optional capability without claiming that their forwarding method implements it.
type AtomicUpdateSupport interface{ SupportsAtomicUpdates() bool }

// VectorHit is one result of a vector search: a stored id and its cosine
// distance from the query (0 = same direction, 2 = opposite).
type VectorHit struct {
	ID       string
	Distance float64
}

// VectorIndex is an optional provider capability: nearest-neighbour search
// over embeddings kept beside a model's records (PostgreSQL with pgvector).
// Each vector belongs to one scope; a search covers the scopes it names and
// only vectors of the query's dimension, so changing the embedding model
// never mixes spaces of different sizes. Providers without it remain usable:
// callers fall back to exact search over the embeddings they stored.
type VectorIndex interface {
	VectorUpsert(ctx context.Context, collection, id, scope string, vector []float32) error
	VectorDelete(ctx context.Context, collection, id string) error
	VectorSearch(ctx context.Context, collection string, scopes []string, vector []float32, limit int) ([]VectorHit, error)
}

// VectorIndexSupport lets wrapping ports report whether the provider they
// forward to really has the VectorIndex capability.
type VectorIndexSupport interface{ SupportsVectorIndex() bool }
