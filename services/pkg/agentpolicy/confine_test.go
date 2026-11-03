package agentpolicy

import (
	"context"
	"errors"
	"testing"
)

func TestConfineKeepsABodyInsideItsSpace(t *testing.T) {
	rooms := map[string]string{"r1": "s1", "r2": "s2"}
	roomSpace := func(_ context.Context, id string) (string, error) {
		if sp, ok := rooms[id]; ok {
			return sp, nil
		}
		return "", errors.New("no room")
	}
	ctx := context.Background()
	for body, ok := range map[string]bool{
		`{}`:                              true,
		`{"space":"s1","room":"r1"}`:      true,
		`{"space_id":"s1","thread":"r1"}`: true,
		`{"text":"s2 r2"}`:                true,
		`{"space":"s2"}`:                  false,
		`{"spaceId":"s2"}`:                false,
		`{"spaces":["s1","s2"]}`:          false,
		`{"room":"r2"}`:                   false,
		`{"space":"s1","room_id":"r2"}`:   false,
		`{"thread_id":"r2"}`:              false,
		`{"temp_thread":"nowhere"}`:       false,
	} {
		if err := Confine(ctx, []byte(body), "s1", roomSpace); (err == nil) != ok {
			t.Errorf("%s: allowed=%v, want %v (%v)", body, err == nil, ok, err)
		}
	}
}
