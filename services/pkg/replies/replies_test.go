package replies

import "testing"

func TestParse(t *testing.T) {
	text, chips := Parse("Send it now?\n<replies>Send | Change the date | Not now | Extra</replies>\n")
	if text != "Send it now?" || len(chips) != 3 || chips[1] != "Change the date" {
		t.Fatalf("%q %v", text, chips)
	}
	if text, chips := Parse("No replies here."); text != "No replies here." || chips != nil {
		t.Fatalf("%q %v", text, chips)
	}
	if _, chips := Parse("<replies>a</replies> and more text"); chips != nil {
		t.Fatal("only a last line offers replies")
	}
}
