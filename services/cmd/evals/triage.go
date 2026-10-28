package main

import (
	"flag"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/plugins/actions/proactive/triage"
)

// triageCase is one labelled message of evals/triage/emails.jsonl.
type triageCase struct {
	ID      string            `json:"id"`
	From    string            `json:"from"`
	Subject string            `json:"subject"`
	Snippet string            `json:"snippet"`
	Headers map[string]string `json:"headers"`
	Label   string            `json:"label"`
	Reason  string            `json:"reason"`
}

// TriageScore is what a run measured.
type TriageScore struct {
	Total, NeedsYou, CanWait     int
	TruePos, FalsePos, FalseNeg  int
	Correct, ByRules, RulesWrong int
	Undecided                    int
	Disagreements                []string
	Rows                         []string
}

// ScoreTriage sorts a labelled set and measures it against its labels.
func ScoreTriage(cases []triageCase, m triage.Model) TriageScore {
	mails := make([]triage.Mail, len(cases))
	byID := map[string]triageCase{}
	for i, c := range cases {
		mails[i] = triage.Mail{ID: c.ID, From: c.From, Subject: c.Subject, Snippet: c.Snippet, Headers: c.Headers, Date: time.Now()}
		byID[c.ID] = c
	}
	verdicts, undecided := triage.Sort("the shop's owner", mails, m, 20)
	sc := TriageScore{Total: len(cases), Undecided: len(undecided)}
	for _, c := range cases {
		if c.Label == triage.NeedsYou {
			sc.NeedsYou++
		} else {
			sc.CanWait++
		}
	}
	for _, v := range verdicts {
		c := byID[v.ID]
		rule := strings.HasPrefix(v.DecidedBy, "rule:")
		if rule {
			sc.ByRules++
		}
		if v.Verdict == c.Label {
			sc.Correct++
		} else {
			if rule {
				sc.RulesWrong++
			}
			sc.Disagreements = append(sc.Disagreements, fmt.Sprintf("- **%s** %q: labelled %s, got %s by %s. Its reason: %q. Label's reason: %q.",
				c.ID, c.Subject, c.Label, v.Verdict, v.DecidedBy, v.Reason, c.Reason))
		}
		switch {
		case v.Verdict == triage.NeedsYou && c.Label == triage.NeedsYou:
			sc.TruePos++
		case v.Verdict == triage.NeedsYou:
			sc.FalsePos++
		case c.Label == triage.NeedsYou:
			sc.FalseNeg++
		}
		sc.Rows = append(sc.Rows, fmt.Sprintf("| %s | %s | %s | %s | %s |", c.ID, c.Label, v.Verdict, v.DecidedBy, strings.ReplaceAll(v.Reason, "|", "/")))
	}
	return sc
}

func runTriage(args []string) error {
	fs := flag.NewFlagSet("triage", flag.ExitOnError)
	set := fs.String("set", "../evals/triage/emails.jsonl", "labelled set")
	out := fs.String("out", "", "write the results here (Markdown)")
	rulesOnly := fs.Bool("rules-only", false, "score the rules alone, with no model")
	_ = fs.Parse(args)
	cases, err := readJSONL[triageCase](*set)
	if err != nil {
		return err
	}
	var m triage.Model
	name := "rules only"
	if !*rulesOnly {
		if m, name, err = model(); err != nil {
			return err
		}
	}
	sc := ScoreTriage(cases, m)
	decided := sc.Total - sc.Undecided
	var b strings.Builder
	fmt.Fprintf(&b, "# Triage eval\n\nRun %s against %d labelled messages (%d needs_you, %d can_wait). Model: %s.\n\n",
		time.Now().UTC().Format(time.RFC3339), sc.Total, sc.NeedsYou, sc.CanWait, name)
	b.WriteString("| Measure | Value |\n| --- | --- |\n")
	fmt.Fprintf(&b, "| Precision for needs_you | %s (%d of %d flagged were right) |\n", pct(sc.TruePos, sc.TruePos+sc.FalsePos), sc.TruePos, sc.TruePos+sc.FalsePos)
	fmt.Fprintf(&b, "| Recall for needs_you | %s (%d of %d that needed them were flagged) |\n", pct(sc.TruePos, sc.NeedsYou), sc.TruePos, sc.NeedsYou)
	fmt.Fprintf(&b, "| Accuracy | %s of %d decided |\n", pct(sc.Correct, decided), decided)
	fmt.Fprintf(&b, "| Decided by rules, no model call | %d of %d, %d wrong |\n", sc.ByRules, sc.Total, sc.RulesWrong)
	fmt.Fprintf(&b, "| Not decided | %d |\n\n", sc.Undecided)
	b.WriteString("## Disagreements\n\n")
	if len(sc.Disagreements) == 0 {
		b.WriteString("None.\n")
	}
	b.WriteString(strings.Join(sc.Disagreements, "\n") + "\n\n## Every verdict\n\n| id | label | verdict | decided by | reason |\n| --- | --- | --- | --- | --- |\n")
	b.WriteString(strings.Join(sc.Rows, "\n") + "\n")
	return write(*out, b.String())
}
