package google

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/untrusted"
)

// callTool runs one of the Google app's functions for [actor], with their own
// Google connection. What it reads from mail is outside content and arrives
// in the untrusted envelope.
func (s *Service) callTool(ctx context.Context, actor, tool string, raw json.RawMessage) (string, error) {
	if !s.isPerson(ctx, actor) {
		return "", errs.Permission("mail and calendar act for a person; this call has none")
	}
	if !s.Connected(ctx, actor) {
		return "", errs.New(errs.CodeUnavailable, "this person has not connected their Google account")
	}
	call := struct{ Tool, ActorID string }{tool, actor}
	var args map[string]any
	_ = json.Unmarshal(raw, &args)
	str := func(k string) string {
		v, _ := args[k].(string)
		return strings.TrimSpace(v)
	}
	switch call.Tool {
	case "gmail_search":
		max := 20
		if v, ok := args["max"].(float64); ok {
			max = int(v)
		}
		mails, err := s.SearchMail(ctx, call.ActorID, str("query"), max)
		if err != nil {
			return "", err
		}
		var b strings.Builder
		for _, m := range mails {
			fmt.Fprintf(&b, "- id %s · %s · from %s · %s\n  %s\n", m.ID, m.Date.Format("2006-01-02 15:04"), m.From, m.Subject, m.Snippet)
		}
		if b.Len() == 0 {
			return "No messages match.", nil
		}
		return untrusted.Wrap("gmail search", b.String()), nil
	case "gmail_read":
		m, err := s.ReadMail(ctx, call.ActorID, str("id"))
		if err != nil {
			return "", err
		}
		text := fmt.Sprintf("From: %s\nTo: %s\nCc: %s\nDate: %s\nSubject: %s\n\n%s", m.From, m.To, m.Cc, m.Date.Format(time.RFC1123Z), m.Subject, m.Body)
		return untrusted.Wrap("email from "+m.From, text), nil
	case "gmail_draft", "gmail_send":
		d := Draft{To: str("to"), Cc: str("cc"), Subject: str("subject"), Body: str("body"), ReplyTo: str("reply_to")}
		if call.Tool == "gmail_draft" {
			id, err := s.SaveDraft(ctx, call.ActorID, d)
			if err != nil {
				return "", err
			}
			return "Saved the draft (" + id + ") in the person's Gmail drafts.", nil
		}
		id, err := s.SendMail(ctx, call.ActorID, d)
		if err != nil {
			return "", err
		}
		return "Sent (" + id + ") to " + d.To + ".", nil
	case "calendar_events":
		from, to := DayBounds(time.Now(), str("timezone"))
		if v := str("from"); v != "" {
			t, err := time.Parse(time.RFC3339, v)
			if err != nil {
				return "", errs.InvalidArgument("from must be an RFC 3339 time")
			}
			from = t
		}
		if v := str("to"); v != "" {
			t, err := time.Parse(time.RFC3339, v)
			if err != nil {
				return "", errs.InvalidArgument("to must be an RFC 3339 time")
			}
			to = t
		}
		events, err := s.Events(ctx, call.ActorID, from, to, str("query"))
		if err != nil {
			return "", err
		}
		if len(events) == 0 {
			return "No events between " + from.Format(time.RFC3339) + " and " + to.Format(time.RFC3339) + ".", nil
		}
		var b strings.Builder
		for _, e := range events {
			when := e.Start.Format("Mon 2 Jan 15:04") + "–" + e.End.Format("15:04")
			if e.AllDay {
				when = e.Start.Format("Mon 2 Jan") + " (all day)"
			}
			fmt.Fprintf(&b, "- %s · %s", when, e.Summary)
			if e.Location != "" {
				b.WriteString(" · " + e.Location)
			}
			if len(e.Attendees) > 0 {
				b.WriteString(" · with " + strings.Join(e.Attendees, ", "))
			}
			b.WriteString("\n")
		}
		return untrusted.Wrap("calendar", b.String()), nil
	case "calendar_create":
		var attendees []string
		for _, a := range strings.Split(str("attendees"), ",") {
			if a = strings.TrimSpace(a); a != "" {
				attendees = append(attendees, a)
			}
		}
		e, err := s.CreateEvent(ctx, call.ActorID, NewEvent{Summary: str("summary"), Start: str("start"), End: str("end"),
			Attendees: attendees, Description: str("description"), Location: str("location")})
		if err != nil {
			return "", err
		}
		return "Created " + e.Summary + " (" + e.Start.Format(time.RFC3339) + ") and invited " + strings.Join(e.Attendees, ", ") + ".", nil
	}
	return "", errs.NotFound("tool " + call.Tool)
}
