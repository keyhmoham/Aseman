package post

import "encoding/json"

// unmarshalJSON tolerantly decodes a JSON string column.
func unmarshalJSON(s string, v any) error {
	return json.Unmarshal([]byte(s), v)
}
