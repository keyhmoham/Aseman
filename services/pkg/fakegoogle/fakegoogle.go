// Package fakegoogle is a small stand-in for Google's OAuth, Gmail and
// Calendar APIs, serving an invented inbox and calendar. It consents at once
// to anything, so a node can be tried (and tested) without a Google account:
// point ASEMAN_FAKE_GOOGLE_URL at it (ignored when ASEMAN_ENV=production).
// GET /__fake/sent shows what was sent, drafted and scheduled through it.
package fakegoogle

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Owner is the invented account the fake signs in as.
const Owner = "sam@harborbikes.example"

// Message is one invented email.
type Message struct {
	ID, Thread, From, To, Subject, Body string
	Age                                 time.Duration
	Labels                              []string
	Headers                             map[string]string
}

// Server is the fake.
type Server struct {
	now func() time.Time

	mu      sync.Mutex
	inbox   []Message
	events  []map[string]any
	sent    []map[string]any
	drafts  []map[string]any
	created []map[string]any
}

// New builds a fake with its invented inbox and today's calendar.
func New() *Server {
	return &Server{now: time.Now, inbox: Inbox()}
}

// Inbox is the invented mail: some that needs its owner, most that can wait.
func Inbox() []Message {
	h := func(kv ...string) map[string]string {
		m := map[string]string{}
		for i := 0; i+1 < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return m
	}
	return []Message{
		{ID: "m01", From: "Priya Raman <priya@cityfleet.example>", Subject: "Fleet order: need your quote by Friday",
			Body: "Hi Sam, we are ready to order 12 cargo bikes for the courier fleet. Can you send the quote by Friday? We sign Monday.", Age: 3 * time.Hour, Labels: []string{"INBOX", "UNREAD", "IMPORTANT"}},
		{ID: "m02", From: "Payments <billing@paygrid.example>", Subject: "Your payout failed",
			Body: "The payout of $2,410.00 to your bank account ending 8812 failed. Update your bank details to receive it.", Age: 5 * time.Hour, Labels: []string{"INBOX", "UNREAD"}},
		{ID: "m03", From: "Spoke Weekly <news@spokeweekly.example>", Subject: "This week in cycling: 9 trends",
			Body: "Our favourite trends of the week...", Age: 7 * time.Hour, Labels: []string{"INBOX", "CATEGORY_PROMOTIONS"},
			Headers: h("List-Unsubscribe", "<mailto:unsub@spokeweekly.example>", "Precedence", "bulk")},
		{ID: "m04", From: "Leo Martin <leo@harborbikes.example>", Subject: "Out of office",
			Body: "I am away until Monday.", Age: 8 * time.Hour, Labels: []string{"INBOX"}, Headers: h("Auto-Submitted", "auto-replied")},
		{ID: "m05", From: "Dana Okafor <dana@okafor.example>", Subject: "Accepted: Wheel build review @ Thu 10am",
			Body: "Dana Okafor has accepted this invitation.", Age: 9 * time.Hour, Labels: []string{"INBOX"},
			Headers: h("Content-Type", "text/calendar; method=REPLY; charset=UTF-8")},
		{ID: "m06", From: "Marco Bellini <marco@bellini.example>", Subject: "Repair still not done?",
			Body: "Sam, my bike has been in the shop for two weeks and I need it for my commute on Wednesday. When will it be ready?", Age: 26 * time.Hour, Labels: []string{"INBOX", "UNREAD"}},
		{ID: "m07", From: "Parts Depot <orders@partsdepot.example>", Subject: "Order PD-4471 has shipped",
			Body: "Your order of 40 inner tubes shipped and arrives Tuesday.", Age: 30 * time.Hour, Labels: []string{"INBOX", "CATEGORY_UPDATES"}},
		{ID: "m08", From: "Ana Silva <ana@harborbikes.example>", Subject: "Thanks for covering Saturday",
			Body: "Thanks again for covering my shift. No need to reply!", Age: 31 * time.Hour, Labels: []string{"INBOX"}},
		{ID: "m09", From: "City Permits <permits@city.example>", Subject: "Sidewalk display permit renewal due",
			Body: "Your sidewalk display permit expires on the 30th. Renew online to avoid a fine.", Age: 40 * time.Hour, Labels: []string{"INBOX", "UNREAD"}},
		{ID: "m10", From: "Trail Club <hello@trailclub.example>", Subject: "Join our autumn ride",
			Body: "Ride with us this autumn!", Age: 44 * time.Hour, Labels: []string{"INBOX", "CATEGORY_SOCIAL"},
			Headers: h("List-Unsubscribe", "<https://trailclub.example/unsub>")},
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	switch {
	case p == "/o/oauth2/v2/auth":
		target, err := url.Parse(r.URL.Query().Get("redirect_uri"))
		if err != nil {
			http.Error(w, "bad redirect_uri", http.StatusBadRequest)
			return
		}
		q := target.Query()
		q.Set("code", "fake-code")
		q.Set("state", r.URL.Query().Get("state"))
		target.RawQuery = q.Encode()
		http.Redirect(w, r, target.String(), http.StatusFound)
	case p == "/token":
		_ = r.ParseForm()
		out := map[string]any{"access_token": "fake-access-" + strconv.FormatInt(s.now().UnixNano(), 36), "expires_in": 3600, "token_type": "Bearer"}
		if r.Form.Get("grant_type") == "authorization_code" {
			out["refresh_token"] = "fake-refresh"
			out["scope"] = "openid email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events"
		}
		writeJSON(w, out)
	case p == "/oauth2/v3/userinfo":
		writeJSON(w, map[string]any{"email": Owner, "email_verified": true})
	case p == "/gmail/v1/users/me/messages" && r.Method == http.MethodGet:
		s.list(w, r)
	case strings.HasPrefix(p, "/gmail/v1/users/me/messages/") && r.Method == http.MethodGet:
		s.get(w, r, strings.TrimPrefix(p, "/gmail/v1/users/me/messages/"))
	case p == "/gmail/v1/users/me/messages/send":
		s.record(w, r, &s.sent)
	case p == "/gmail/v1/users/me/drafts":
		s.record(w, r, &s.drafts)
	case p == "/calendar/v3/calendars/primary/events" && r.Method == http.MethodGet:
		s.calendar(w, r)
	case p == "/calendar/v3/calendars/primary/events" && r.Method == http.MethodPost:
		s.record(w, r, &s.created)
	case p == "/__fake/sent":
		s.mu.Lock()
		defer s.mu.Unlock()
		writeJSON(w, map[string]any{"sent": s.sent, "drafts": s.drafts, "events": s.created})
	default:
		http.NotFound(w, r)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// matches is a little of Gmail's search syntax: is:unread, newer_than:Nd/h,
// from:, subject:, category:, and plain words.
func (s *Server) matches(m Message, q string) bool {
	for _, term := range strings.Fields(strings.ToLower(q)) {
		switch {
		case term == "is:unread":
			if !has(m.Labels, "UNREAD") {
				return false
			}
		case term == "in:inbox":
			if !has(m.Labels, "INBOX") {
				return false
			}
		case strings.HasPrefix(term, "newer_than:"):
			v := strings.TrimPrefix(term, "newer_than:")
			if len(v) < 2 {
				continue
			}
			n, _ := strconv.Atoi(v[:len(v)-1])
			unit := map[byte]time.Duration{'d': 24 * time.Hour, 'h': time.Hour, 'm': 30 * 24 * time.Hour}[v[len(v)-1]]
			if unit > 0 && m.Age > time.Duration(n)*unit {
				return false
			}
		case strings.HasPrefix(term, "from:"):
			if !strings.Contains(strings.ToLower(m.From), strings.TrimPrefix(term, "from:")) {
				return false
			}
		case strings.HasPrefix(term, "subject:"):
			if !strings.Contains(strings.ToLower(m.Subject), strings.TrimPrefix(term, "subject:")) {
				return false
			}
		case strings.HasPrefix(term, "category:"):
			if !has(m.Labels, "CATEGORY_"+strings.ToUpper(strings.TrimPrefix(term, "category:"))) {
				return false
			}
		case strings.HasPrefix(term, "-") || strings.Contains(term, ":"):
		default:
			if !strings.Contains(strings.ToLower(m.Subject+" "+m.Body+" "+m.From), term) {
				return false
			}
		}
	}
	return true
}

func has(list []string, v string) bool {
	for _, l := range list {
		if l == v {
			return true
		}
	}
	return false
}

func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	max, _ := strconv.Atoi(r.URL.Query().Get("maxResults"))
	if max <= 0 {
		max = 100
	}
	var ids []map[string]string
	for _, m := range s.inbox {
		if s.matches(m, r.URL.Query().Get("q")) && len(ids) < max {
			ids = append(ids, map[string]string{"id": m.ID, "threadId": "t" + m.ID})
		}
	}
	writeJSON(w, map[string]any{"messages": ids, "resultSizeEstimate": len(ids)})
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, id string) {
	for _, m := range s.inbox {
		if m.ID != id {
			continue
		}
		date := s.now().Add(-m.Age)
		headers := []map[string]string{{"name": "From", "value": m.From}, {"name": "To", "value": Owner},
			{"name": "Subject", "value": m.Subject}, {"name": "Date", "value": date.Format(time.RFC1123Z)},
			{"name": "Message-ID", "value": "<" + m.ID + "@fake.example>"}}
		for k, v := range m.Headers {
			headers = append(headers, map[string]string{"name": k, "value": v})
		}
		payload := map[string]any{"mimeType": "text/plain", "headers": headers}
		if r.URL.Query().Get("format") == "full" {
			payload["body"] = map[string]string{"data": base64.URLEncoding.EncodeToString([]byte(m.Body))}
		}
		writeJSON(w, map[string]any{"id": m.ID, "threadId": "t" + m.ID, "labelIds": m.Labels, "snippet": clip(m.Body, 120),
			"internalDate": strconv.FormatInt(date.UnixMilli(), 10), "payload": payload})
		return
	}
	http.Error(w, `{"error":{"message":"not found"}}`, http.StatusNotFound)
}

func (s *Server) calendar(w http.ResponseWriter, r *http.Request) {
	from, _ := time.Parse(time.RFC3339, r.URL.Query().Get("timeMin"))
	to, _ := time.Parse(time.RFC3339, r.URL.Query().Get("timeMax"))
	day := s.now().UTC().Truncate(24 * time.Hour)
	all := []map[string]any{
		event("e1", "Stand-up with the shop", day.Add(9*time.Hour), day.Add(9*time.Hour+15*time.Minute), "Ana Silva <ana@harborbikes.example>"),
		event("e2", "City Fleet: quote walkthrough", day.Add(14*time.Hour), day.Add(15*time.Hour), "priya@cityfleet.example"),
		event("e3", "Wheel build review", day.Add(24*time.Hour+10*time.Hour), day.Add(24*time.Hour+11*time.Hour), "dana@okafor.example"),
	}
	var items []map[string]any
	for _, e := range all {
		start, _ := time.Parse(time.RFC3339, e["start"].(map[string]string)["dateTime"])
		if (from.IsZero() || !start.Before(from)) && (to.IsZero() || start.Before(to)) {
			items = append(items, e)
		}
	}
	writeJSON(w, map[string]any{"items": items})
}

func event(id, summary string, start, end time.Time, attendee string) map[string]any {
	return map[string]any{"id": id, "summary": summary, "status": "confirmed",
		"start": map[string]string{"dateTime": start.Format(time.RFC3339)}, "end": map[string]string{"dateTime": end.Format(time.RFC3339)},
		"organizer": map[string]string{"email": Owner}, "attendees": []map[string]string{{"email": attendee}}}
}

func (s *Server) record(w http.ResponseWriter, r *http.Request, into *[]map[string]any) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	s.mu.Lock()
	id := fmt.Sprintf("fake-%d", len(s.sent)+len(s.drafts)+len(s.created)+1)
	body["id"] = id
	*into = append(*into, body)
	s.mu.Unlock()
	writeJSON(w, map[string]any{"id": id, "summary": body["summary"], "htmlLink": "https://calendar.example/" + id})
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// Sent is everything sent, drafted and scheduled so far.
func (s *Server) Sent() (sent, drafts, events []map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]map[string]any(nil), s.sent...), append([]map[string]any(nil), s.drafts...), append([]map[string]any(nil), s.created...)
}
