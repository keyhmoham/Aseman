package helper

import "testing"

func TestNormalizeHandle(t *testing.T) {
	ok := map[string]string{"Shawn": "shawn", " @bob_1 ": "bob_1", "a.b-c": "a.b-c", "x1y": "x1y"}
	for in, want := range ok {
		if got, err := NormalizeHandle(in); err != nil || got != want {
			t.Errorf("%q: got %q, %v want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "ab", "has space", "<script>", "emoji😀", "-lead", "trail.", "a/b", "aseman", "Lead", "x" + string(make([]byte, 40))} {
		if got, err := NormalizeHandle(in); err == nil {
			t.Errorf("%q should be refused, got %q", in, got)
		}
	}
}

func TestSanitizeHandle(t *testing.T) {
	if got := SanitizeHandle("u_jo+hn@x"); got != "u_jo_hn_x" {
		t.Fatalf("got %q", got)
	}
	if got := SanitizeHandle("!"); len(got) < HandleMin {
		t.Fatalf("too short: %q", got)
	}
	if _, err := NormalizeHandle(SanitizeHandle("u_ Ünï+code")); err != nil {
		t.Fatal(err)
	}
}
