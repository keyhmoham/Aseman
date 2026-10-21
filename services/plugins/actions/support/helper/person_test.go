package helper

import "testing"

func TestPersonName(t *testing.T) {
	for _, c := range []struct {
		name    string
		profile map[string]any
		handle  string
		want    string
	}{
		{"first and last name", map[string]any{"firstName": "Shayan", "lastName": "Pahlavan"}, "shayan", "Shayan Pahlavan"},
		{"a first name alone is a name", map[string]any{"firstName": " Ada "}, "ada", "Ada"},
		{"an old display name is not a name", map[string]any{"displayName": "u_shayan"}, "shayan", "shayan"},
		{"nothing set falls back to the handle", map[string]any{}, "ada", "ada"},
	} {
		if got := PersonName(c.profile, c.handle); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	if got := BotName(map[string]any{"displayName": "Aseman"}, "aseman"); got != "Aseman" {
		t.Errorf("a bot keeps the name it was created with: %q", got)
	}
}
