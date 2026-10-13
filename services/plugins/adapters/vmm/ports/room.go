package vmm

import "context"

// roomKey carries the room id a request is running in through the context.
type roomKey struct{}

// WithRoom attaches the room id a request is being processed in (a chat room of
// a space) to the context. Agent tool calls executed during the request can then
// post messages/files into the ACTUAL room instead of silently falling back to
// the space's general room. Empty clears any room.
func WithRoom(ctx context.Context, roomID string) context.Context {
	return context.WithValue(ctx, roomKey{}, roomID)
}

// RoomFrom returns the room id attached to the context, or "" when the request
// is not tied to a specific room.
func RoomFrom(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	s, _ := ctx.Value(roomKey{}).(string)
	return s
}
