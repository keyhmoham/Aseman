// Package mongodb implements the database port on MongoDB (document store).
// Models map to collections; the universal id string is the document _id.
package mongodb

import (
	"context"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/cfg"
	"github.com/tradera/tradera/plugins/adapters/database/ports"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// Adapter is the MongoDB database plugin.
type Adapter struct {
	base.Base
	client *mongo.Client
	db     *mongo.Database
	cfg    database.Config
	mu     sync.RWMutex
	models map[string]database.Model
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "mongodb",
			Category:    api.CategoryDatabase,
			Version:     "1.0.0",
			Description: "MongoDB document provider",
			Provides:    []string{"database"},
			Log:         log,
		},
		models: map[string]database.Model{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	a.cfg = cfg.Database(deps.Config)
	if a.cfg.DSN == "" {
		return errs.InvalidArgument("mongodb adapter requires config.dsn (mongodb://...)")
	}
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return a.Open(ctx, a.cfg) }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements database.Database.
func (a *Adapter) Name() string { return "mongodb" }

// Open implements database.Database.
func (a *Adapter) Open(ctx context.Context, c database.Config) error {
	opts := options.Client().ApplyURI(c.DSN)
	client, err := mongo.Connect(ctx, opts)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "connect mongodb")
	}
	if err := client.Ping(ctx, nil); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "ping mongodb")
	}
	a.client = client
	name := "tradera"
	if n := c.Options["database"]; n != "" {
		name = n
	}
	a.db = client.Database(name)
	return nil
}

// Close implements database.Database.
func (a *Adapter) Close(ctx context.Context) error {
	if a.client != nil {
		return a.client.Disconnect(ctx)
	}
	return nil
}

// Health implements database.Database.
func (a *Adapter) Health(ctx context.Context) database.Health {
	if a.client == nil {
		return database.Health{OK: false, Message: "mongodb not open"}
	}
	if err := a.client.Ping(ctx, nil); err != nil {
		return database.Health{OK: false, Message: err.Error()}
	}
	return database.Health{OK: true, Message: "mongodb healthy"}
}

// RegisterModel implements database.Database (collections are implicit).
func (a *Adapter) RegisterModel(ctx context.Context, m database.Model) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.models[m.Name] = m
	return nil
}

// UnregisterModel implements database.Database.
func (a *Adapter) UnregisterModel(ctx context.Context, name string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.models, name)
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
	a.mu.RLock()
	defer a.mu.RUnlock()
	m, ok := a.models[name]
	if !ok {
		return database.Model{}, errs.NotFound("model " + name)
	}
	return m, nil
}

func (a *Adapter) coll(name string) *mongo.Collection {
	return a.db.Collection(name)
}

func toDoc(m database.Model, v any) (bson.M, error) {
	row, err := database.Decode(m, v)
	if err != nil {
		return nil, err
	}
	doc := bson.M{}
	for k, val := range row {
		doc[k] = val
	}
	return doc, nil
}

// Create implements database.Database.
func (a *Adapter) Create(ctx context.Context, model, id string, v any) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	doc, err := toDoc(m, v)
	if err != nil {
		return err
	}
	doc["_id"] = id
	if _, err := a.coll(model).InsertOne(ctx, doc); err != nil {
		if mongo.IsDuplicateKeyError(err) {
			return errs.AlreadyExists("record " + id + " in " + model)
		}
		return errs.Wrap(errs.CodePlugin, err, "insert "+model)
	}
	return nil
}

// Get implements database.Database.
func (a *Adapter) Get(ctx context.Context, model, id string, out any) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	var doc bson.M
	if err := a.coll(model).FindOne(ctx, bson.M{"_id": id}).Decode(&doc); err != nil {
		if err == mongo.ErrNoDocuments {
			return errs.NotFound("record " + id + " in " + model)
		}
		return errs.Wrap(errs.CodePlugin, err, "find "+model)
	}
	return decodeDoc(m, doc, out)
}

// Update implements database.Database.
func (a *Adapter) Update(ctx context.Context, model, id string, v any) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	doc, err := toDoc(m, v)
	if err != nil {
		return err
	}
	res, err := a.coll(model).ReplaceOne(ctx, bson.M{"_id": id}, doc)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "replace "+model)
	}
	if res.MatchedCount == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// Delete implements database.Database.
func (a *Adapter) Delete(ctx context.Context, model, id string) error {
	res, err := a.coll(model).DeleteOne(ctx, bson.M{"_id": id})
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "delete "+model)
	}
	if res.DeletedCount == 0 {
		return errs.NotFound("record " + id + " in " + model)
	}
	return nil
}

// List implements database.Database.
func (a *Adapter) List(ctx context.Context, model string, f database.Filter, out any) error {
	m, err := a.model(model)
	if err != nil {
		return err
	}
	filter := bson.M{}
	for k, v := range f.Equal {
		filter[k] = v
	}
	for k, vs := range f.In {
		filter[k] = bson.M{"$in": vs}
	}
	for k, v := range f.GreaterThan {
		filter[k] = bson.M{"$gt": v}
	}
	for k, v := range f.LessThan {
		filter[k] = bson.M{"$lt": v}
	}
	opts := options.Find()
	if f.Limit > 0 {
		opts.SetLimit(int64(f.Limit))
	}
	if f.Offset > 0 {
		opts.SetSkip(int64(f.Offset))
	}
	if f.OrderBy != "" {
		dir := -1
		if f.Asc {
			dir = 1
		}
		opts.SetSort(bson.M{f.OrderBy: dir})
	}
	cur, err := a.coll(model).Find(ctx, filter, opts)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "find "+model)
	}
	defer cur.Close(ctx)
	var docs []bson.M
	if err := cur.All(ctx, &docs); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "decode "+model)
	}
	rows := make([]map[string]any, 0, len(docs))
	for _, d := range docs {
		delete(d, "_id")
		row := make(map[string]any, len(d))
		for k, v := range d {
			row[k] = v
		}
		rows = append(rows, row)
	}
	return database.DecodeList(m, rows, out)
}

// Count implements database.Database.
func (a *Adapter) Count(ctx context.Context, model string, f database.Filter) (int64, error) {
	filter := bson.M{}
	for k, v := range f.Equal {
		filter[k] = v
	}
	n, err := a.coll(model).CountDocuments(ctx, filter)
	if err != nil {
		return 0, errs.Wrap(errs.CodePlugin, err, "count "+model)
	}
	return n, nil
}

// Transaction implements database.Database (single-document semantics; real
// multi-document transactions require a replica set, so we run serially).
func (a *Adapter) Transaction(ctx context.Context, fn func(ctx context.Context, tx database.Tx) error) error {
	return fn(ctx, &txAdapter{adapter: a})
}

// Query implements database.Database: raw aggregation is not exposed.
func (a *Adapter) Query(ctx context.Context, model string, q database.Query, out any) error {
	return errs.New(errs.CodeUnavailable, "native queries not supported by mongodb adapter")
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
		return 0, errs.NotFound("field " + field)
	}
	return f.Kind, nil
}

func decodeDoc(m database.Model, doc bson.M, out any) error {
	row := make(map[string]any, len(doc))
	for k, v := range doc {
		if k == "_id" {
			row["id"] = v
			continue
		}
		row[k] = v
	}
	// Normalize BSON time types.
	for k, v := range row {
		if t, ok := v.(time.Time); ok {
			row[k] = t
		}
	}
	return database.Encode(m, row, out)
}

type txAdapter struct {
	adapter *Adapter
}

func (t *txAdapter) Create(ctx context.Context, model, id string, v any) error {
	return t.adapter.Create(ctx, model, id, v)
}
func (t *txAdapter) Get(ctx context.Context, model, id string, out any) error {
	return t.adapter.Get(ctx, model, id, out)
}
func (t *txAdapter) Update(ctx context.Context, model, id string, v any) error {
	return t.adapter.Update(ctx, model, id, v)
}
func (t *txAdapter) Delete(ctx context.Context, model, id string) error {
	return t.adapter.Delete(ctx, model, id)
}
func (t *txAdapter) Commit(ctx context.Context) error   { return nil }
func (t *txAdapter) Rollback(ctx context.Context) error { return nil }

func (a *Adapter) CompareAndSwap(ctx context.Context, model, id string, expected map[string]any, value any) (bool, error) {
	m, err := a.model(model)
	if err != nil {
		return false, err
	}
	doc, err := toDoc(m, value)
	if err != nil {
		return false, err
	}
	doc["_id"] = id
	doc["id"] = id
	filter := bson.M{"_id": id}
	for key, want := range expected {
		if _, ok := m.Field(key); !ok {
			return false, errs.InvalidArgument("unknown condition field")
		}
		filter[key] = want
	}
	result, err := a.coll(model).ReplaceOne(ctx, filter, doc)
	if err != nil {
		return false, err
	}
	return result.MatchedCount == 1, nil
}

// Compile-time checks keep interchangeable providers on the same contracts.
var _ database.Database = (*Adapter)(nil)
var _ database.AtomicUpdater = (*Adapter)(nil)
