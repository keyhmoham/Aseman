// Package sqlcommon implements the shared relational engine behind the
// PostgreSQL and MySQL database adapters. It translates the generic
// model/filter model into dialect-specific SQL. Both adapters share this code
// so their semantics are identical.
package sqlcommon

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/database/ports"

	mysqlDriver "github.com/go-sql-driver/mysql"
)

// arg converts a stored value into a driver argument. JSON columns are stored
// as json.RawMessage ([]byte) by the record decoder; passing raw []byte to pgx
// sends it as bytea (hex), which postgres rejects for a json/jsonb column.
// Converting to a string lets the driver bind it as JSON text.
func arg(v any) any {
	switch b := v.(type) {
	case json.RawMessage:
		return string(b)
	case []byte:
		return string(b)
	}
	return v
}

// colArg converts a stored value for a specific column. JSON columns must
// always carry valid JSON: an empty string (e.g. an unset session.Meta) is
// invalid for a jsonb column, so it is stored as the JSON null literal.
func colArg(m database.Model, col string, v any) any {
	if f, ok := m.Field(col); ok && f.Kind == database.KindJSON {
		if s, isStr := v.(string); isStr {
			if strings.TrimSpace(s) == "" {
				return "null"
			}
			return s
		}
	}
	return arg(v)
}

// Dialect captures SQL flavour differences.
type Dialect struct {
	Name        string
	Placeholder func(int) string
	Quote       func(string) string
	ColumnType  func(database.Kind) string
	// Upsert is optional; when nil, Create is a plain INSERT.
	UpsertClause func(table string, fields []string) string
	// AddColumn returns an ALTER TABLE statement adding a column. Dialects that
	// support ADD COLUMN IF NOT EXISTS make RegisterModel idempotent across
	// schema changes on pre-existing tables.
	AddColumn func(table, column, ctype string) string
}

// Postgres dialect.
func Postgres() Dialect {
	return Dialect{
		Name:        "postgres",
		Placeholder: func(i int) string { return fmt.Sprintf("$%d", i) },
		Quote:       func(s string) string { return `"` + s + `"` },
		AddColumn: func(table, column, ctype string) string {
			return fmt.Sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s %s",
				`"`+table+`"`, `"`+column+`"`, ctype)
		},
		ColumnType: func(k database.Kind) string {
			switch k {
			case database.KindString:
				return "TEXT"
			case database.KindInt64:
				return "BIGINT"
			case database.KindFloat64:
				return "DOUBLE PRECISION"
			case database.KindBool:
				return "BOOLEAN"
			case database.KindJSON:
				return "JSONB"
			case database.KindTime:
				return "TIMESTAMPTZ"
			case database.KindBytes:
				return "BYTEA"
			default:
				return "TEXT"
			}
		},
	}
}

// MySQL dialect.
func MySQL() Dialect {
	return Dialect{
		Name:        "mysql",
		Placeholder: func(int) string { return "?" },
		Quote:       func(s string) string { return "`" + s + "`" },
		AddColumn: func(table, column, ctype string) string {
			return fmt.Sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s %s",
				"`"+table+"`", "`"+column+"`", ctype)
		},
		ColumnType: func(k database.Kind) string {
			switch k {
			case database.KindString:
				return "TEXT"
			case database.KindInt64:
				return "BIGINT"
			case database.KindFloat64:
				return "DOUBLE"
			case database.KindBool:
				return "TINYINT(1)"
			case database.KindJSON:
				return "JSON"
			case database.KindTime:
				return "DATETIME(6)"
			case database.KindBytes:
				return "LONGBLOB"
			default:
				return "TEXT"
			}
		},
	}
}

// Engine is a dialect-bound relational store.
type Engine struct {
	dialect Dialect
	db      *sql.DB
	log     *logger.Logger
	models  map[string]database.Model
}

// NewEngine creates an engine over an open *sql.DB.
func NewEngine(d Dialect, db *sql.DB, log *logger.Logger) *Engine {
	return &Engine{dialect: d, db: db, log: log, models: map[string]database.Model{}}
}

// DB exposes the underlying handle (for transactions).
func (e *Engine) DB() *sql.DB { return e.db }

func (e *Engine) q(name string) string { return e.dialect.Quote(name) }

func (e *Engine) model(name string) (database.Model, error) {
	m, ok := e.models[name]
	if !ok {
		return database.Model{}, errs.NotFound("model " + name)
	}
	return m, nil
}

// RegisterModel creates the physical table (idempotent) and records the schema.
// Columns added to a model after a table already exists are migrated in with
// ALTER TABLE ADD COLUMN IF NOT EXISTS, so schema evolution (e.g. new message
// attachment columns) applies to pre-existing persistent databases.
func (e *Engine) RegisterModel(ctx context.Context, m database.Model) error {
	cols := make([]string, 0, len(m.Fields)+2)
	cols = append(cols, e.q("id")+" "+e.dialect.ColumnType(database.KindString)+" PRIMARY KEY")
	for _, f := range m.Fields {
		if f.Name == "id" {
			continue
		}
		col := e.q(f.Name) + " " + e.dialect.ColumnType(f.Kind)
		if f.Unique {
			col += " UNIQUE"
		}
		cols = append(cols, col)
	}
	create := fmt.Sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", e.q(m.Table), strings.Join(cols, ", "))
	if _, err := e.db.ExecContext(ctx, create); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "create table "+m.Table)
	}
	// Bring pre-existing tables up to date with any new columns. Dialects with
	// ADD COLUMN IF NOT EXISTS make this a no-op for columns that exist.
	if e.dialect.AddColumn != nil {
		for _, f := range m.Fields {
			if f.Name == "id" {
				continue
			}
			stmt := e.dialect.AddColumn(m.Table, f.Name, e.dialect.ColumnType(f.Kind))
			if _, err := e.db.ExecContext(ctx, stmt); err != nil {
				// Older MySQL without ADD COLUMN IF NOT EXISTS errors on columns
				// that already exist; treat duplicate-column as success.
				if !isDuplicateColumn(err) {
					return errs.Wrap(errs.CodePlugin, err, "add column "+f.Name+" to "+m.Table)
				}
			}
		}
	}
	for _, f := range m.Fields {
		if f.Index && !f.Unique {
			idx := fmt.Sprintf("CREATE INDEX IF NOT EXISTS %s ON %s (%s)",
				e.q("idx_"+m.Table+"_"+f.Name), e.q(m.Table), e.q(f.Name))
			_, _ = e.db.ExecContext(ctx, idx)
		}
	}
	e.models[m.Name] = m
	e.log.Debug("model registered", "model", m.Name, "table", m.Table)
	return nil
}

// isDuplicateColumn reports whether a DDL error is caused by an already-present
// column (the "duplicate column name" / "column already exists" family).
func isDuplicateColumn(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "duplicate column") ||
		strings.Contains(msg, "already exists") ||
		strings.Contains(msg, "duplicate_column") ||
		strings.Contains(msg, "42701")
}

// UnregisterModel removes the schema descriptor (table stays, avoids data loss).
func (e *Engine) UnregisterModel(ctx context.Context, name string) error {
	if _, ok := e.models[name]; !ok {
		return errs.NotFound("model " + name)
	}
	delete(e.models, name)
	return nil
}

// Models lists registered models.
func (e *Engine) Models() []database.Model {
	out := make([]database.Model, 0, len(e.models))
	for _, m := range e.models {
		out = append(out, m)
	}
	return out
}

// FieldNames returns the persisted field names of a model.
func (e *Engine) FieldNames(model string) ([]string, error) {
	m, err := e.model(model)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(m.Fields))
	for _, f := range m.Fields {
		names = append(names, f.Name)
	}
	return names, nil
}

// KindOf returns the kind of a model field.
func (e *Engine) KindOf(model, field string) (database.Kind, error) {
	m, err := e.model(model)
	if err != nil {
		return 0, err
	}
	f, ok := m.Field(field)
	if !ok {
		return 0, errs.NotFound("field " + field)
	}
	return f.Kind, nil
}

func (e *Engine) columns(m database.Model) []string {
	out := []string{"id"}
	for _, f := range m.Fields {
		if f.Name == "id" {
			continue
		}
		out = append(out, f.Name)
	}
	return out
}

// Create inserts a record.
func (e *Engine) Create(ctx context.Context, model, id string, v any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	row["id"] = id
	cols := e.columns(m)
	values := make([]any, 0, len(cols))
	holders := make([]string, 0, len(cols))
	for i, c := range cols {
		values = append(values, colArg(m, c, row[c]))
		holders = append(holders, e.dialect.Placeholder(i+1))
	}
	sqlText := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)",
		e.q(m.Table), e.quoteList(cols), strings.Join(holders, ", "))
	if _, err := e.db.ExecContext(ctx, sqlText, values...); err != nil {
		if isUniqueViolation(err) {
			return errs.AlreadyExists("record " + id + " in " + model)
		}
		return errs.Wrap(errs.CodePlugin, err, "insert into "+m.Table)
	}
	return nil
}

// Get reads a single record by id.
func (e *Engine) Get(ctx context.Context, model, id string, out any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	cols := e.columns(m)
	sqlText := fmt.Sprintf("SELECT %s FROM %s WHERE %s = %s",
		e.quoteList(cols), e.q(m.Table), e.q("id"), e.dialect.Placeholder(1))
	rows, err := e.db.QueryContext(ctx, sqlText, id)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "select from "+m.Table)
	}
	defer rows.Close()
	if !rows.Next() {
		return errs.NotFound("record " + id + " in " + model)
	}
	return e.scan(rows, m, out)
}

// Update replaces a record by id.
func (e *Engine) Update(ctx context.Context, model, id string, v any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	cols := e.columns(m)
	set := make([]string, 0, len(cols))
	values := make([]any, 0, len(cols)+1)
	for i, c := range cols {
		set = append(set, fmt.Sprintf("%s = %s", e.q(c), e.dialect.Placeholder(i+1)))
		values = append(values, colArg(m, c, row[c]))
	}
	values = append(values, id)
	sqlText := fmt.Sprintf("UPDATE %s SET %s WHERE %s = %s",
		e.q(m.Table), strings.Join(set, ", "), e.q("id"), e.dialect.Placeholder(len(values)))
	res, err := e.db.ExecContext(ctx, sqlText, values...)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "update "+m.Table)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// Delete removes a record by id.
func (e *Engine) Delete(ctx context.Context, model, id string) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	sqlText := fmt.Sprintf("DELETE FROM %s WHERE %s = %s", e.q(m.Table), e.q("id"), e.dialect.Placeholder(1))
	res, err := e.db.ExecContext(ctx, sqlText, id)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "delete from "+m.Table)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// List queries records by filter.
func (e *Engine) List(ctx context.Context, model string, f database.Filter, out any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	cols := e.columns(m)
	where, args := e.buildWhere(m, f)
	base := fmt.Sprintf("SELECT %s FROM %s%s", e.quoteList(cols), e.q(m.Table), where)
	if f.OrderBy != "" {
		dir := "DESC"
		if f.Asc {
			dir = "ASC"
		}
		base += fmt.Sprintf(" ORDER BY %s %s", e.q(f.OrderBy), dir)
	}
	if f.Limit > 0 {
		base += fmt.Sprintf(" LIMIT %d", f.Limit)
	}
	if f.Offset > 0 {
		base += fmt.Sprintf(" OFFSET %d", f.Offset)
	}
	rows, err := e.db.QueryContext(ctx, base, args...)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "list "+m.Table)
	}
	defer rows.Close()
	return e.scanList(rows, m, out)
}

// Count counts records by filter.
func (e *Engine) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	m, err := e.model(model)
	if err != nil {
		return 0, err
	}
	where, args := e.buildWhere(m, f)
	sqlText := fmt.Sprintf("SELECT COUNT(*) FROM %s%s", e.q(m.Table), where)
	var n int64
	if err := e.db.QueryRowContext(ctx, sqlText, args...).Scan(&n); err != nil {
		return 0, errs.Wrap(errs.CodePlugin, err, "count "+m.Table)
	}
	return n, nil
}

// Query runs a raw query returning records into out (*[]T or *[]map).
func (e *Engine) Query(ctx context.Context, model string, q database.Query, out any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	sqlText := q.Raw
	if q.Limit > 0 && !strings.Contains(strings.ToLower(sqlText), "limit") {
		sqlText += fmt.Sprintf(" LIMIT %d", q.Limit)
	}
	rows, err := e.db.QueryContext(ctx, sqlText, q.Args...)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "raw query on "+m.Table)
	}
	defer rows.Close()
	return e.scanList(rows, m, out)
}

// CreateTx inserts a record inside an explicit transaction.
func (e *Engine) CreateTx(ctx context.Context, tx *sql.Tx, model, id string, v any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	row["id"] = id
	cols := e.columns(m)
	values := make([]any, 0, len(cols))
	holders := make([]string, 0, len(cols))
	for i, c := range cols {
		values = append(values, colArg(m, c, row[c]))
		holders = append(holders, e.dialect.Placeholder(i+1))
	}
	sqlText := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)",
		e.q(m.Table), e.quoteList(cols), strings.Join(holders, ", "))
	if _, err := tx.ExecContext(ctx, sqlText, values...); err != nil {
		if isUniqueViolation(err) {
			return errs.AlreadyExists("record " + id + " in " + model)
		}
		return errs.Wrap(errs.CodePlugin, err, "insert into "+m.Table)
	}
	return nil
}

// GetTx reads a record inside an explicit transaction.
func (e *Engine) GetTx(ctx context.Context, tx *sql.Tx, model, id string, out any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	cols := e.columns(m)
	sqlText := fmt.Sprintf("SELECT %s FROM %s WHERE %s = %s",
		e.quoteList(cols), e.q(m.Table), e.q("id"), e.dialect.Placeholder(1))
	rows, err := tx.QueryContext(ctx, sqlText, id)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "select from "+m.Table)
	}
	defer rows.Close()
	if !rows.Next() {
		return errs.NotFound("record " + id + " in " + model)
	}
	return e.scan(rows, m, out)
}

// UpdateTx updates a record inside an explicit transaction.
func (e *Engine) UpdateTx(ctx context.Context, tx *sql.Tx, model, id string, v any) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	row, err := database.Decode(m, v)
	if err != nil {
		return err
	}
	cols := e.columns(m)
	set := make([]string, 0, len(cols))
	values := make([]any, 0, len(cols)+1)
	for i, c := range cols {
		set = append(set, fmt.Sprintf("%s = %s", e.q(c), e.dialect.Placeholder(i+1)))
		values = append(values, colArg(m, c, row[c]))
	}
	values = append(values, id)
	sqlText := fmt.Sprintf("UPDATE %s SET %s WHERE %s = %s",
		e.q(m.Table), strings.Join(set, ", "), e.q("id"), e.dialect.Placeholder(len(values)))
	res, err := tx.ExecContext(ctx, sqlText, values...)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "update "+m.Table)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// DeleteTx deletes a record inside an explicit transaction.
func (e *Engine) DeleteTx(ctx context.Context, tx *sql.Tx, model, id string) error {
	m, err := e.model(model)
	if err != nil {
		return err
	}
	sqlText := fmt.Sprintf("DELETE FROM %s WHERE %s = %s", e.q(m.Table), e.q("id"), e.dialect.Placeholder(1))
	res, err := tx.ExecContext(ctx, sqlText, id)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "delete from "+m.Table)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// buildWhere composes WHERE clauses from a filter.
func (e *Engine) buildWhere(m database.Model, f database.Filter) (string, []any) {
	var clauses []string
	var args []any
	i := 0
	next := func() string { i++; return e.dialect.Placeholder(i) }
	for k, v := range f.Equal {
		clauses = append(clauses, fmt.Sprintf("%s = %s", e.q(k), next()))
		args = append(args, arg(v))
	}
	for k, vs := range f.In {
		holders := make([]string, 0, len(vs))
		for _, v := range vs {
			holders = append(holders, next())
			args = append(args, arg(v))
		}
		clauses = append(clauses, fmt.Sprintf("%s IN (%s)", e.q(k), strings.Join(holders, ", ")))
	}
	for k, v := range f.GreaterThan {
		clauses = append(clauses, fmt.Sprintf("%s > %s", e.q(k), next()))
		args = append(args, arg(v))
	}
	for k, v := range f.LessThan {
		clauses = append(clauses, fmt.Sprintf("%s < %s", e.q(k), next()))
		args = append(args, arg(v))
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

func (e *Engine) quoteList(cols []string) string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = e.q(c)
	}
	return strings.Join(out, ", ")
}

func (e *Engine) scan(rows *sql.Rows, m database.Model, out any) error {
	cols, err := rows.Columns()
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "read columns")
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	if err := rows.Scan(ptrs...); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "scan row")
	}
	row := map[string]any{}
	for i, c := range cols {
		row[strings.Trim(c, `"`)] = vals[i]
	}
	return database.Encode(m, row, out)
}

func (e *Engine) scanList(rows *sql.Rows, m database.Model, out any) error {
	cols, err := rows.Columns()
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "read columns")
	}
	var records []map[string]any
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return errs.Wrap(errs.CodePlugin, err, "scan row")
		}
		row := map[string]any{}
		for i, c := range cols {
			row[strings.Trim(c, `"`)] = vals[i]
		}
		records = append(records, row)
	}
	return database.DecodeList(m, records, out)
}

func (e *Engine) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	m, err := e.model(model)
	if err != nil {
		return false, err
	}
	row, err := database.Decode(m, value)
	if err != nil {
		return false, err
	}
	row["id"] = id
	var sets, where []string
	var values []any
	for _, col := range e.columns(m) {
		sets = append(sets, fmt.Sprintf("%s = %s", e.q(col), e.dialect.Placeholder(len(values)+1)))
		values = append(values, colArg(m, col, row[col]))
	}
	values = append(values, id)
	where = append(where, fmt.Sprintf("%s = %s", e.q("id"), e.dialect.Placeholder(len(values))))
	for key, want := range expected {
		if _, ok := m.Field(key); !ok {
			return false, errs.InvalidArgument("unknown condition field")
		}
		if want == nil {
			where = append(where, fmt.Sprintf("%s IS NULL", e.q(key)))
			continue
		}
		values = append(values, colArg(m, key, want))
		where = append(where, fmt.Sprintf("%s = %s", e.q(key), e.dialect.Placeholder(len(values))))
	}
	result, err := e.db.ExecContext(ctx, fmt.Sprintf("UPDATE %s SET %s WHERE %s", e.q(m.Table), strings.Join(sets, ", "), strings.Join(where, " AND ")), values...)
	if err != nil {
		return false, errs.Wrap(errs.CodePlugin, err, "compare and swap")
	}
	n, err := result.RowsAffected()
	return n == 1, err
}

func isUniqueViolation(err error) bool {
	var state interface{ SQLState() string }
	if errors.As(err, &state) && state.SQLState() == "23505" {
		return true
	}
	var mysqlError *mysqlDriver.MySQLError
	return errors.As(err, &mysqlError) && mysqlError.Number == 1062
}
