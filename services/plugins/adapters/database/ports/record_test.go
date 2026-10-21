package database_test

import (
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func TestEncodeJSONStructFromDriverRepresentations(t *testing.T) {
	type outcome struct {
		Finalized bool `json:"finalized"`
		Tokens    int  `json:"tokens"`
	}
	type record struct {
		ID       identity.ID `db:"id"`
		Outcome  outcome     `db:"outcome"`
		Optional *outcome    `db:"optional"`
	}
	model := database.Model{Name: "sample", Fields: []database.Field{{Name: "id", Kind: database.KindString}, {Name: "outcome", Kind: database.KindJSON}, {Name: "optional", Kind: database.KindJSON}}}
	id := "683fe4c9253629bbf7314ec5725db58f"
	for name, value := range map[string]any{"postgres-text": `{"finalized":true,"tokens":42}`, "mysql-bytes": []byte(`{"finalized":true,"tokens":42}`), "raw-json": json.RawMessage(`{"finalized":true,"tokens":42}`), "document": map[string]any{"finalized": true, "tokens": 42}} {
		t.Run(name, func(t *testing.T) {
			var got record
			if err := database.Encode(model, map[string]any{"id": id, "outcome": value, "optional": value}, &got); err != nil {
				t.Fatal(err)
			}
			if got.ID.String() != id || !got.Outcome.Finalized || got.Outcome.Tokens != 42 || got.Optional == nil || *got.Optional != got.Outcome {
				t.Fatalf("incorrect record: %+v", got)
			}
		})
	}
}
