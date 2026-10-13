package timeline

import (
	"time"

	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	return []database.Model{spaceModel(), cursorModel(), stateModel()}
}

const (
	spacesTable  = "timeline_spaces"
	cursorsTable = "timeline_cursors"
	stateTable   = "timeline_state"
)

func spaceModel() database.Model {
	return database.Model{Name: spacesTable, Table: spacesTable, Fields: []database.Field{
		f("id", database.KindString), f("kb_id", database.KindString), f("source_id", database.KindString),
		f("secret", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

func cursorModel() database.Model {
	return database.Model{Name: cursorsTable, Table: cursorsTable, Fields: []database.Field{
		f("id", database.KindString), f("at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

func stateModel() database.Model {
	return database.Model{Name: stateTable, Table: stateTable, Fields: []database.Field{
		f("id", database.KindString), f("secret", database.KindString), f("updated_at", database.KindTime),
	}}
}

// Space is a space's timeline: its knowledge base in Utopia and the source the
// node pushes the space's events to. Secret is the source's push key, sealed
// with the node key.
type Space struct {
	ID        string    `db:"id" json:"id"`
	KBID      string    `db:"kb_id" json:"kb_id"`
	SourceID  string    `db:"source_id" json:"source_id"`
	Secret    string    `db:"secret" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

// Cursor is how far into one feed the node has pushed.
type Cursor struct {
	ID        string    `db:"id" json:"id"`
	At        time.Time `db:"at" json:"at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

// State is the node's own standing in Utopia: the read token agents' timeline
// queries go out with, sealed with the node key.
type State struct {
	ID        string    `db:"id" json:"id"`
	Secret    string    `db:"secret" json:"-"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}
