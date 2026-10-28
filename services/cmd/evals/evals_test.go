package main

import (
	"path/filepath"
	"runtime"
	"testing"
)

func setPath(rel string) string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "evals", rel)
}

// The rules never decide mail that needs the person (they only say "can
// wait"), on the labelled set.
func TestTriageRulesOnLabelledSet(t *testing.T) {
	cases, err := readJSONL[triageCase](setPath("triage/emails.jsonl"))
	if err != nil || len(cases) != 60 {
		t.Fatalf("%d %v", len(cases), err)
	}
	sc := ScoreTriage(cases, nil)
	if sc.RulesWrong != 0 || sc.ByRules < 10 {
		t.Fatalf("rules decided %d with %d wrong", sc.ByRules, sc.RulesWrong)
	}
}

func TestReplyChipScoring(t *testing.T) {
	cases, err := readJSONL[chipCase](setPath("reply-chips/cases.jsonl"))
	if err != nil || len(cases) == 0 {
		t.Fatal(err)
	}
	// A model that offers the acceptable answers exactly when it should.
	m := func(_, user string) (string, string, error) {
		for _, c := range cases {
			if c.Expects && len(user) > len(c.Message) && user[len(user)-len(c.Message):] == c.Message {
				return c.Message + "\n<replies>" + c.Acceptable[0] + " | " + c.Acceptable[1] + "</replies>", "fake", nil
			}
		}
		return "ok", "fake", nil
	}
	sc := ScoreChips(cases, m)
	if sc.Offered != sc.Expected || sc.Spurious != 0 || sc.Relevant != sc.Offered || sc.Malformed != 0 {
		t.Fatalf("%+v", sc)
	}
}
