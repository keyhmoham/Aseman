package postgres

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// The pgvector side tables: one per collection, created on first use.
//
//	vec_<collection>(id text primary key, scope text, dim int, embedding vector)
//
// The column has no fixed dimension, so a new embedding model needs no
// migration; searches compare only vectors of the query's dimension.

var collectionName = regexp.MustCompile(`^[a-z][a-z0-9_]{0,40}$`)

type vectorState struct {
	mu      sync.Mutex
	ready   map[string]bool
	enabled *bool
}

func (a *Adapter) vectors() *vectorState {
	a.vecOnce.Do(func() { a.vec = &vectorState{ready: map[string]bool{}} })
	return a.vec
}

func (a *Adapter) ensureVectorTable(ctx context.Context, collection string) (string, error) {
	if !collectionName.MatchString(collection) {
		return "", errs.InvalidArgument("invalid vector collection name")
	}
	if a.db == nil {
		return "", errs.New(errs.CodeUnavailable, "postgres is not open")
	}
	st := a.vectors()
	st.mu.Lock()
	defer st.mu.Unlock()
	table := "vec_" + collection
	if st.ready[collection] {
		return table, nil
	}
	if _, err := a.db.ExecContext(ctx, `CREATE EXTENSION IF NOT EXISTS vector`); err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, "pgvector is not available on this PostgreSQL")
	}
	stmts := []string{
		fmt.Sprintf(`CREATE TABLE IF NOT EXISTS %s (id text PRIMARY KEY, scope text NOT NULL, dim int NOT NULL, embedding vector NOT NULL)`, table),
		fmt.Sprintf(`CREATE INDEX IF NOT EXISTS %s_scope ON %s (scope, dim)`, table, table),
	}
	for _, s := range stmts {
		if _, err := a.db.ExecContext(ctx, s); err != nil {
			return "", errs.Wrap(errs.CodeInternal, err, "create vector table")
		}
	}
	st.ready[collection] = true
	return table, nil
}

func vectorLiteral(v []float32) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, x := range v {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatFloat(float64(x), 'g', -1, 32))
	}
	b.WriteByte(']')
	return b.String()
}

// VectorUpsert implements database.VectorIndex.
func (a *Adapter) VectorUpsert(ctx context.Context, collection, id, scope string, vector []float32) error {
	if len(vector) == 0 {
		return errs.InvalidArgument("empty vector")
	}
	table, err := a.ensureVectorTable(ctx, collection)
	if err != nil {
		return err
	}
	_, err = a.db.ExecContext(ctx, fmt.Sprintf(
		`INSERT INTO %s (id, scope, dim, embedding) VALUES ($1, $2, $3, $4::vector)
		 ON CONFLICT (id) DO UPDATE SET scope = EXCLUDED.scope, dim = EXCLUDED.dim, embedding = EXCLUDED.embedding`, table),
		id, scope, len(vector), vectorLiteral(vector))
	if err != nil {
		return errs.Wrap(errs.CodeInternal, err, "store vector")
	}
	return nil
}

// VectorDelete implements database.VectorIndex.
func (a *Adapter) VectorDelete(ctx context.Context, collection, id string) error {
	table, err := a.ensureVectorTable(ctx, collection)
	if err != nil {
		return err
	}
	if _, err := a.db.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s WHERE id = $1`, table), id); err != nil {
		return errs.Wrap(errs.CodeInternal, err, "delete vector")
	}
	return nil
}

// VectorSearch implements database.VectorIndex (cosine distance, exact).
func (a *Adapter) VectorSearch(ctx context.Context, collection string, scopes []string, vector []float32, limit int) ([]database.VectorHit, error) {
	if len(vector) == 0 || len(scopes) == 0 {
		return nil, nil
	}
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	table, err := a.ensureVectorTable(ctx, collection)
	if err != nil {
		return nil, err
	}
	rows, err := a.db.QueryContext(ctx, fmt.Sprintf(
		`SELECT id, embedding <=> $1::vector AS d FROM %s WHERE dim = $2 AND scope = ANY($3) ORDER BY d LIMIT $4`, table),
		vectorLiteral(vector), len(vector), scopes, limit)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "vector search")
	}
	defer rows.Close()
	var out []database.VectorHit
	for rows.Next() {
		var h database.VectorHit
		if err := rows.Scan(&h.ID, &h.Distance); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

var _ database.VectorIndex = (*Adapter)(nil)
