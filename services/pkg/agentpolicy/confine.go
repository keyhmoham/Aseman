package agentpolicy

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
)

// What a request body names: the spaces, and the rooms and threads (a thread
// is a room), it is about. Actions name them in a few ways; these are all of
// them in the platform's action bodies (see action_schemas.json).
var (
	spaceKeys = map[string]bool{"space": true, "space_id": true, "spaceId": true, "spaces": true, "space_ids": true}
	roomKeys  = map[string]bool{"room": true, "room_id": true, "roomId": true, "rooms": true, "room_ids": true,
		"thread": true, "thread_id": true, "threadId": true, "temp_thread": true}
)

// Refs are the space and room ids a body names at its top level.
func Refs(body []byte) (spaces, rooms []string) {
	var top map[string]json.RawMessage
	if len(body) == 0 || json.Unmarshal(body, &top) != nil {
		return nil, nil
	}
	for k, raw := range top {
		isSpace, isRoom := spaceKeys[k], roomKeys[k]
		if !isSpace && !isRoom {
			continue
		}
		for _, id := range ids(raw) {
			if isSpace {
				spaces = append(spaces, id)
			} else {
				rooms = append(rooms, id)
			}
		}
	}
	return spaces, rooms
}

// ids is a string or a list of strings ("" and other values name nothing).
func ids(raw json.RawMessage) []string {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		if one = strings.TrimSpace(one); one != "" {
			return []string{one}
		}
		return nil
	}
	var many []any
	if json.Unmarshal(raw, &many) != nil {
		return nil
	}
	var out []string
	for _, v := range many {
		if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, strings.TrimSpace(s))
		}
	}
	return out
}

// Confine refuses a body that names a space other than own, or a room or
// thread that is not in own. roomSpace says which space a room is in.
func Confine(ctx context.Context, body []byte, own string, roomSpace func(ctx context.Context, room string) (string, error)) error {
	spaces, rooms := Refs(body)
	for _, sp := range spaces {
		if sp != own {
			return errs.Permission("this works only inside its own space")
		}
	}
	for _, r := range rooms {
		sp, err := roomSpace(ctx, r)
		if err != nil || sp != own {
			return errs.Permission("this works only with the rooms of its own space")
		}
	}
	return nil
}
