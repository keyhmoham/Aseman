package emailtpl

import (
	"strings"
	"testing"
)

func TestEveryDefaultIsValidAndRendersWithItsSamples(t *testing.T) {
	for _, d := range Definitions() {
		if err := Validate(d, d.Default); err != nil {
			t.Fatalf("%s: %v", d.Key, err)
		}
		r := Render(d, nil, Samples(d))
		if r.Subject == "" || !strings.Contains(r.HTML, "<h1") || strings.Contains(r.Text, "{{") || strings.Contains(r.HTML, "{{") {
			t.Fatalf("%s rendered badly: %+v", d.Key, r)
		}
	}
}

func TestOverridesUseValuesEscapedAndDropEmptyParagraphs(t *testing.T) {
	d, _ := Find("credit_granted")
	c := Content{Subject: "Hi {{name}}", Heading: "<b>Yay</b>", Body: "{{credits}} for {{name}}\n\n{{note_line}}"}
	r := Render(d, &c, map[string]string{"name": "<script>", "credits": "5 credits"})
	if r.Subject != "Hi <script>" || strings.Contains(r.HTML, "<script>") || strings.Contains(r.HTML, "<b>Yay") {
		t.Fatalf("not escaped: %+v", r)
	}
	if strings.Count(r.HTML, "<p ") != 1 {
		t.Fatalf("the empty note paragraph must be dropped: %s", r.HTML)
	}
}

func TestValidateRefusesUnknownValuesAndEmptyParts(t *testing.T) {
	d, _ := Find("password_reset")
	if Validate(d, Content{Subject: "s", Heading: "h", Body: "{{credits}}"}) == nil {
		t.Fatal("a value this email doesn’t have must be refused")
	}
	if Validate(d, Content{Subject: "s", Heading: "", Body: "b"}) == nil {
		t.Fatal("an empty heading must be refused")
	}
	if Validate(d, Content{Subject: "a\nb", Heading: "h", Body: "b"}) == nil {
		t.Fatal("a multi-line subject must be refused")
	}
}
