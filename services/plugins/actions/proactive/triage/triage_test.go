package triage

import (
	"errors"
	"testing"
)

func TestRulesOnlySayCanWait(t *testing.T) {
	cases := map[string]Mail{
		"rule:bulk":              {ID: "1", Subject: "9 trends", Headers: map[string]string{"List-Unsubscribe": "<mailto:x>"}},
		"rule:auto-reply":        {ID: "2", Subject: "Out of office", Headers: map[string]string{"Auto-Submitted": "auto-replied"}},
		"rule:calendar-response": {ID: "3", Subject: "Accepted: Review @ Thu", Headers: map[string]string{"Content-Type": "text/calendar; method=REPLY"}},
	}
	for want, m := range cases {
		v, ok := Rule(m)
		if !ok || v.DecidedBy != want || v.Verdict != CanWait {
			t.Errorf("%s: %+v %v", want, v, ok)
		}
	}
	// A no-reply sender with something wrong is not a rule's to settle.
	if _, ok := Rule(Mail{ID: "4", From: "noreply@bank.example", Subject: "Your payout failed"}); ok {
		t.Fatal("rules must not decide mail that may need the person")
	}
	if _, ok := Rule(Mail{ID: "5", Subject: "Invitation: Planning @ Mon", Headers: map[string]string{}}); ok {
		t.Fatal("an invitation itself may need an answer")
	}
	if _, ok := Rule(Mail{ID: "6", Subject: "Auto-Submitted: no", Headers: map[string]string{"Auto-Submitted": "no"}}); ok {
		t.Fatal("Auto-Submitted: no is a person")
	}
}

func TestSortUsesTheModelForTheRest(t *testing.T) {
	mails := []Mail{
		{ID: "a", Subject: "Promo", Labels: []string{"CATEGORY_PROMOTIONS"}},
		{ID: "b", Subject: "Quote by Friday?"},
		{ID: "c", Subject: "Thanks!"},
	}
	model := func(system, user string) (string, string, error) {
		return "Sure: {\"verdicts\":[{\"id\":\"b\",\"verdict\":\"needs_you\",\"reason\":\"Priya needs a quote by Friday.\"}," +
			"{\"id\":\"c\",\"verdict\":\"can_wait\",\"reason\":\"\"}]}", "m1", nil
	}
	verdicts, undecided := Sort("Sam", mails, model, 10)
	if len(verdicts) != 2 || verdicts[1].DecidedBy != "model:m1" || verdicts[1].Verdict != NeedsYou {
		t.Fatalf("%+v", verdicts)
	}
	if len(undecided) != 1 || undecided[0] != "c" {
		t.Fatalf("a verdict without a reason is not a verdict: %v", undecided)
	}
	_, undecided = Sort("Sam", mails, func(string, string) (string, string, error) { return "", "", errors.New("down") }, 10)
	if len(undecided) != 2 {
		t.Fatalf("a failed model call decides nothing: %v", undecided)
	}
}
