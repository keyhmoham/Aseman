package helper

import "strings"

// PersonName is how a person is named wherever they appear (a post, a list,
// a chat): their first and last name when they gave them, else their handle.
// People have a handle, a first name and a last name; there is no separate
// display name.
func PersonName(profile map[string]any, handle string) string {
	first, _ := profile["firstName"].(string)
	last, _ := profile["lastName"].(string)
	if full := strings.TrimSpace(strings.TrimSpace(first) + " " + strings.TrimSpace(last)); full != "" {
		return full
	}
	return handle
}

// BotName is the name a bot was created with (kept in its profile), else its handle.
func BotName(profile map[string]any, handle string) string {
	if name, _ := profile["displayName"].(string); strings.TrimSpace(name) != "" {
		return strings.TrimSpace(name)
	}
	return handle
}
