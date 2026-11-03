package timeline

import (
	"time"

	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	return []database.Model{entryModel(), cursorModel()}
}

const (
	entriesTable = "timeline_entries"
	cursorsTable = "timeline_cursors"
)

func entryModel() database.Model {
	return database.Model{Name: entriesTable, Table: entriesTable, Fields: []database.Field{
		f("id", database.KindString), {Name: "space_id", Kind: database.KindString, Index: true}, f("kind", database.KindString),
		{Name: "at", Kind: database.KindTime, Index: true}, f("summary", database.KindString), f("subjects", database.KindString),
		f("recorded_at", database.KindTime),
	}}
}

func cursorModel() database.Model {
	return database.Model{Name: cursorsTable, Table: cursorsTable, Fields: []database.Field{
		f("id", database.KindString), f("at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

// Entry is one dated thing that happened in a space: what (Summary, rendered
// from its statements), to whom (Subjects) and when (At). Kind is the feed it
// came from (requests, tools, messages, usage, files, members, rooms,
// routines, …). Its id says what it states, so an entry is never edited: a
// changed record becomes a new entry.
type Entry struct {
	ID         string    `db:"id" json:"id"`
	SpaceID    string    `db:"space_id" json:"space_id"`
	Kind       string    `db:"kind" json:"kind"`
	At         time.Time `db:"at" json:"at"`
	Summary    string    `db:"summary" json:"summary"`
	Subjects   string    `db:"subjects" json:"subjects"`
	RecordedAt time.Time `db:"recorded_at" json:"recorded_at"`
}

// Cursor is how far into one feed the node has read.
type Cursor struct {
	ID        string    `db:"id" json:"id"`
	At        time.Time `db:"at" json:"at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}
