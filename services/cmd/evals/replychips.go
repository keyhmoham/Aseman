package main

import (
	"flag"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/replies"
	"github.com/aseman/aseman/plugins/actions/proactive/triage"
)

// chipCase is one labelled agent message of evals/reply-chips/cases.jsonl.
type chipCase struct {
	ID         string   `json:"id"`
	Message    string   `json:"message"`
	Expects    bool     `json:"expects_chips"`
	Acceptable []string `json:"acceptable"`
}

// chipInstruction is the runtime's (aseman_agents/untrusted.py).
const chipInstruction = `When your answer asks the person to choose or confirm something, end it with one last line: <replies>first | second | third</replies> — up to three short answers they can tap (each under 40 characters), the most likely first. Leave it out when there is nothing to choose.`

// ChipScore is what a run measured.
type ChipScore struct {
	Total, Expected, Offered, Missed, Spurious, Relevant, Malformed int
	Rows                                                            []string
}

// ScoreChips asks the model to finish each message and scores the replies.
func ScoreChips(cases []chipCase, m triage.Model) ChipScore {
	var sc ChipScore
	for _, c := range cases {
		sc.Total++
		answer, _, err := m(chipInstruction, "Repeat this answer to the person exactly, adding the replies line only if it applies:\n\n"+c.Message)
		if err != nil {
			sc.Malformed++
			continue
		}
		_, chips := replies.Parse(answer)
		raw := strings.Count(answer, "<replies>")
		if raw > 1 || (raw == 1 && chips == nil) {
			sc.Malformed++
		}
		got := len(chips) > 0
		relevant := false
		for _, chip := range chips {
			for _, a := range c.Acceptable {
				if strings.Contains(strings.ToLower(chip), strings.ToLower(a)) {
					relevant = true
				}
			}
		}
		switch {
		case c.Expects && got:
			sc.Offered++
			if relevant {
				sc.Relevant++
			}
		case c.Expects:
			sc.Missed++
		case got:
			sc.Spurious++
		}
		if c.Expects {
			sc.Expected++
		}
		sc.Rows = append(sc.Rows, fmt.Sprintf("| %s | %v | %s | %v |", c.ID, c.Expects, strings.Join(chips, " / "), relevant))
	}
	return sc
}

func runReplyChips(args []string) error {
	fs := flag.NewFlagSet("reply-chips", flag.ExitOnError)
	set := fs.String("set", "../evals/reply-chips/cases.jsonl", "labelled set")
	out := fs.String("out", "", "write the results here (Markdown)")
	_ = fs.Parse(args)
	cases, err := readJSONL[chipCase](*set)
	if err != nil {
		return err
	}
	m, name, err := model()
	if err != nil {
		return err
	}
	sc := ScoreChips(cases, m)
	var b strings.Builder
	fmt.Fprintf(&b, "# Reply chips eval\n\nRun %s against %d messages (%d should offer replies). Model: %s.\n\n", time.Now().UTC().Format(time.RFC3339), sc.Total, sc.Expected, name)
	b.WriteString("| Measure | Value |\n| --- | --- |\n")
	fmt.Fprintf(&b, "| Offered when they should | %s (%d of %d) |\n", pct(sc.Offered, sc.Expected), sc.Offered, sc.Expected)
	fmt.Fprintf(&b, "| Offered when they should not | %d of %d |\n", sc.Spurious, sc.Total-sc.Expected)
	fmt.Fprintf(&b, "| Replies that answer the question | %s (%d of %d offered) |\n", pct(sc.Relevant, sc.Offered), sc.Relevant, sc.Offered)
	fmt.Fprintf(&b, "| Malformed | %d |\n\n| id | expects | replies | relevant |\n| --- | --- | --- | --- |\n", sc.Malformed)
	b.WriteString(strings.Join(sc.Rows, "\n") + "\n")
	return write(*out, b.String())
}
