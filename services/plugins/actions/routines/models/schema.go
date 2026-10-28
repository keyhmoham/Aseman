package routine

import "github.com/aseman/aseman/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{routines(), routineRuns(), demonstrations()} }

func routines() database.Model {
	return database.Model{
		Name:  "routines",
		Table: "routines",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("creator_id", database.KindString),
			f("name", database.KindString), f("type", database.KindString),
			f("target", database.KindString), f("task", database.KindString),
			f("delay_sec", database.KindInt64), f("interval_sec", database.KindInt64),
			f("at", database.KindString), f("timezone", database.KindString),
			f("next_run_at", database.KindTime), f("last_run_at", database.KindTime),
			f("last_result", database.KindString), f("status", database.KindString),
			f("active_run_id", database.KindString), f("retry_at", database.KindTime), f("retry_count", database.KindInt64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func routineRuns() database.Model {
	return database.Model{Name: "routine_runs", Table: "routine_runs", Fields: []database.Field{
		f("id", database.KindString), f("routine_id", database.KindString), f("space_id", database.KindString), f("room_id", database.KindString), f("creator_id", database.KindString),
		f("scheduled_at", database.KindTime), f("status", database.KindString), f("attempt", database.KindInt64), f("result", database.KindString), f("target", database.KindString), f("task", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}}
}
