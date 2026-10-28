package google

import (
	"context"
	"encoding/base64"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// Mail is one message as the brief, triage and agents read it.
type Mail struct {
	ID       string            `json:"id"`
	ThreadID string            `json:"thread_id"`
	From     string            `json:"from"`
	To       string            `json:"to,omitempty"`
	Cc       string            `json:"cc,omitempty"`
	Subject  string            `json:"subject"`
	Date     time.Time         `json:"date"`
	Snippet  string            `json:"snippet"`
	Labels   []string          `json:"labels,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`
	Body     string            `json:"body,omitempty"`
	// MessageID is the RFC 822 Message-ID, for replying in the thread.
	MessageID string `json:"message_id,omitempty"`
}

// headersWanted are the headers triage reads.
var headersWanted = []string{"From", "To", "Cc", "Subject", "Date", "Message-ID", "List-Unsubscribe", "List-Id", "Precedence",
	"Auto-Submitted", "X-Autoreply", "X-Autorespond", "Content-Type", "Reply-To"}

type gmailMessage struct {
	ID       string   `json:"id"`
	ThreadID string   `json:"threadId"`
	LabelIDs []string `json:"labelIds"`
	Snippet  string   `json:"snippet"`
	Internal string   `json:"internalDate"`
	Payload  part     `json:"payload"`
}

type part struct {
	MimeType string `json:"mimeType"`
	Headers  []struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	} `json:"headers"`
	Body struct {
		Data string `json:"data"`
	} `json:"body"`
	Parts []part `json:"parts"`
}

// SearchMail finds the person's messages with a Gmail query, newest first,
// with their headers (not their bodies).
func (s *Service) SearchMail(ctx context.Context, accountID, query string, max int) ([]Mail, error) {
	if max <= 0 || max > 50 {
		max = 20
	}
	q := url.Values{"q": {query}, "maxResults": {fmt.Sprint(max)}}
	var list struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
	}
	if err := s.api(ctx, accountID, http.MethodGet, s.endpoints().Gmail+"/users/me/messages?"+q.Encode(), nil, &list); err != nil {
		return nil, err
	}
	out := make([]Mail, len(list.Messages))
	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		first error
	)
	slots := make(chan struct{}, 6)
	for i, m := range list.Messages {
		wg.Add(1)
		go func(i int, id string) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			mail, err := s.message(ctx, accountID, id, false)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				if first == nil {
					first = err
				}
				return
			}
			out[i] = *mail
		}(i, m.ID)
	}
	wg.Wait()
	kept := out[:0]
	for _, m := range out {
		if m.ID != "" {
			kept = append(kept, m)
		}
	}
	if len(kept) == 0 && first != nil {
		return nil, first
	}
	return kept, nil
}

// ReadMail is one message with its plain-text body.
func (s *Service) ReadMail(ctx context.Context, accountID, id string) (*Mail, error) {
	if strings.TrimSpace(id) == "" {
		return nil, errs.InvalidArgument("message id required")
	}
	return s.message(ctx, accountID, id, true)
}

func (s *Service) message(ctx context.Context, accountID, id string, full bool) (*Mail, error) {
	q := url.Values{"format": {"metadata"}}
	if full {
		q.Set("format", "full")
	} else {
		for _, h := range headersWanted {
			q.Add("metadataHeaders", h)
		}
	}
	var m gmailMessage
	if err := s.api(ctx, accountID, http.MethodGet, s.endpoints().Gmail+"/users/me/messages/"+url.PathEscape(id)+"?"+q.Encode(), nil, &m); err != nil {
		return nil, err
	}
	mail := &Mail{ID: m.ID, ThreadID: m.ThreadID, Snippet: m.Snippet, Labels: m.LabelIDs, Headers: map[string]string{}}
	for _, h := range m.Payload.Headers {
		mail.Headers[h.Name] = h.Value
		switch strings.ToLower(h.Name) {
		case "from":
			mail.From = h.Value
		case "to":
			mail.To = h.Value
		case "cc":
			mail.Cc = h.Value
		case "subject":
			mail.Subject = decodeHeader(h.Value)
		case "message-id":
			mail.MessageID = h.Value
		case "date":
			if t, err := parseMailDate(h.Value); err == nil {
				mail.Date = t
			}
		}
	}
	if mail.Date.IsZero() && m.Internal != "" {
		var ms int64
		if _, err := fmt.Sscan(m.Internal, &ms); err == nil {
			mail.Date = time.UnixMilli(ms).UTC()
		}
	}
	if full {
		mail.Body = clip(textOf(m.Payload), 20000)
	}
	return mail, nil
}

func decodeHeader(v string) string {
	dec := new(mime.WordDecoder)
	if out, err := dec.DecodeHeader(v); err == nil {
		return out
	}
	return v
}

func parseMailDate(v string) (time.Time, error) {
	for _, layout := range []string{time.RFC1123Z, time.RFC1123, "Mon, 2 Jan 2006 15:04:05 -0700", "2 Jan 2006 15:04:05 -0700",
		"Mon, 2 Jan 2006 15:04:05 -0700 (MST)"} {
		if t, err := time.Parse(layout, strings.TrimSpace(v)); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, errs.InvalidArgument("date")
}

// textOf is a message's plain text: its text/plain part, or its HTML with
// the tags taken out.
func textOf(p part) string {
	if strings.HasPrefix(p.MimeType, "text/plain") && p.Body.Data != "" {
		return decodeBody(p.Body.Data)
	}
	for _, sub := range p.Parts {
		if t := textOf(sub); t != "" && strings.HasPrefix(sub.MimeType, "text/plain") {
			return t
		}
	}
	for _, sub := range p.Parts {
		if t := textOf(sub); t != "" {
			return t
		}
	}
	if strings.HasPrefix(p.MimeType, "text/html") && p.Body.Data != "" {
		return stripHTML(decodeBody(p.Body.Data))
	}
	return ""
}

func decodeBody(data string) string {
	raw, err := base64.URLEncoding.DecodeString(data)
	if err != nil {
		raw, err = base64.RawURLEncoding.DecodeString(data)
		if err != nil {
			return ""
		}
	}
	return string(raw)
}

func stripHTML(h string) string {
	var b strings.Builder
	in := false
	for _, r := range h {
		switch {
		case r == '<':
			in = true
		case r == '>':
			in = false
			b.WriteByte(' ')
		case !in:
			b.WriteRune(r)
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// Draft is a message to write.
type Draft struct {
	To      string `json:"to"`
	Cc      string `json:"cc,omitempty"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
	ReplyTo string `json:"reply_to,omitempty"`
}

// rfc822 builds the raw message, threaded when it answers one.
func (s *Service) rfc822(ctx context.Context, accountID string, d Draft) (string, string, error) {
	if strings.TrimSpace(d.To) == "" || strings.TrimSpace(d.Body) == "" {
		return "", "", errs.InvalidArgument("a message needs to and body")
	}
	threadID := ""
	subject := d.Subject
	var b strings.Builder
	b.WriteString("To: " + headerSafe(d.To) + "\r\n")
	if d.Cc != "" {
		b.WriteString("Cc: " + headerSafe(d.Cc) + "\r\n")
	}
	if d.ReplyTo != "" {
		orig, err := s.message(ctx, accountID, d.ReplyTo, false)
		if err != nil {
			return "", "", err
		}
		threadID = orig.ThreadID
		if subject == "" {
			subject = orig.Subject
			if !strings.HasPrefix(strings.ToLower(subject), "re:") {
				subject = "Re: " + subject
			}
		}
		if orig.MessageID != "" {
			b.WriteString("In-Reply-To: " + headerSafe(orig.MessageID) + "\r\nReferences: " + headerSafe(orig.MessageID) + "\r\n")
		}
	}
	b.WriteString("Subject: " + mime.QEncoding.Encode("utf-8", headerSafe(subject)) + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n")
	b.WriteString(d.Body)
	return base64.URLEncoding.EncodeToString([]byte(b.String())), threadID, nil
}

func headerSafe(v string) string {
	return strings.NewReplacer("\r", " ", "\n", " ").Replace(strings.TrimSpace(v))
}

// SaveDraft keeps a draft in the person's Gmail.
func (s *Service) SaveDraft(ctx context.Context, accountID string, d Draft) (string, error) {
	raw, thread, err := s.rfc822(ctx, accountID, d)
	if err != nil {
		return "", err
	}
	msg := map[string]any{"raw": raw}
	if thread != "" {
		msg["threadId"] = thread
	}
	var out struct {
		ID string `json:"id"`
	}
	if err := s.api(ctx, accountID, http.MethodPost, s.endpoints().Gmail+"/users/me/drafts", map[string]any{"message": msg}, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

// SendMail sends from the person's Gmail. The governance gate asked the
// person before this is reached.
func (s *Service) SendMail(ctx context.Context, accountID string, d Draft) (string, error) {
	raw, thread, err := s.rfc822(ctx, accountID, d)
	if err != nil {
		return "", err
	}
	msg := map[string]any{"raw": raw}
	if thread != "" {
		msg["threadId"] = thread
	}
	var out struct {
		ID string `json:"id"`
	}
	if err := s.api(ctx, accountID, http.MethodPost, s.endpoints().Gmail+"/users/me/messages/send", msg, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
