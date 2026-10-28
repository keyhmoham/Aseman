package responsibilities

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/governance/models/egress"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Polls and schedules run on the node's clock: every minute the due ones
// (NextRun passed) are checked, each then set to run again after its
// interval. A poll fires for what is new since it last looked (mail, events,
// feed items), or when an answer changes (an API, an app); the first look
// only learns what is there.

// seenCap bounds how many item ids a poll remembers.
const seenCap = 200

// maxFiresPerLook bounds how many runs one look starts.
const maxFiresPerLook = 5

// Run checks the due polls and schedules every minute.
func (s *Service) Run(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Tick(ctx)
		}
	}
}

// Tick runs every poll and schedule that is due now.
func (s *Service) Tick(ctx context.Context) {
	var rows []rm.Responsibility
	if err := s.R.List(ctx, "responsibilities", database.Filter{Equal: map[string]any{"enabled": true},
		LessThan: map[string]any{"next_run": s.now().UTC()}, Limit: 500}, &rows); err != nil {
		return
	}
	for i := range rows {
		r := &rows[i]
		spec, ok := TriggerFor(r.Trigger)
		if !ok || spec.Delivery == DeliveryHook || r.NextRun.IsZero() {
			continue
		}
		s.look(ctx, r)
	}
}

// look runs one due poll or schedule and sets when it is due next.
func (s *Service) look(ctx context.Context, r *rm.Responsibility) {
	now := s.now().UTC()
	// Claim it first, so a slow look is not started twice.
	r.NextRun = nextRun(r, now)
	if err := s.R.Update(ctx, "responsibilities", r.ID, r); err != nil {
		return
	}
	var err error
	switch r.Trigger {
	case rm.TriggerSchedule:
		_, err = s.Fire(ctx, r, "schedule", "It is "+now.Format(time.RFC1123)+": the scheduled time for this responsibility.")
	case rm.TriggerEmail:
		err = s.pollEmail(ctx, r)
	case rm.TriggerCalendar:
		err = s.pollCalendar(ctx, r)
	case rm.TriggerFeed:
		err = s.pollFeed(ctx, r)
	case rm.TriggerAPI:
		err = s.pollAPI(ctx, r)
	case rm.TriggerApp:
		err = s.pollApp(ctx, r)
	}
	if err != nil {
		var cur rm.Responsibility
		if s.R.Get(ctx, "responsibilities", r.ID, &cur) == nil {
			cur.LastResult = clip("could not check: "+err.Error(), 500)
			_ = s.R.Update(ctx, "responsibilities", r.ID, &cur)
		}
	}
}

// remember stores what a look learned (cursor, seen ids, fingerprint)
// without overwriting what the runs it started recorded.
func (s *Service) remember(ctx context.Context, r *rm.Responsibility, update func(cur *rm.Responsibility)) {
	var cur rm.Responsibility
	if s.R.Get(ctx, "responsibilities", r.ID, &cur) != nil {
		return
	}
	update(&cur)
	_ = s.R.Update(ctx, "responsibilities", r.ID, &cur)
}

func matches(r *rm.Responsibility, text string) bool {
	return r.Keyword == "" || strings.Contains(strings.ToLower(text), strings.ToLower(r.Keyword))
}

func seen(list []string, id string) bool {
	for _, v := range list {
		if v == id {
			return true
		}
	}
	return false
}

func addSeen(list []string, ids ...string) []string {
	list = append(list, ids...)
	if len(list) > seenCap {
		list = list[len(list)-seenCap:]
	}
	return list
}

// pollEmail fires for new matching mail.
func (s *Service) pollEmail(ctx context.Context, r *rm.Responsibility) error {
	if s.Google == nil || !s.Google.Connected(ctx, r.OwnerID) {
		return errors.New("the person's Google account is not connected")
	}
	mails, err := s.Google.SearchMail(ctx, r.OwnerID, EmailQuery(r), 10)
	if err != nil {
		return err
	}
	cursor, fired := r.Cursor, 0
	for j := len(mails) - 1; j >= 0 && fired < maxFiresPerLook; j-- {
		m := mails[j]
		if !m.Date.After(r.Cursor) {
			continue
		}
		event := fmt.Sprintf("Email id %s from %s on %s\nSubject: %s\n%s", m.ID, m.From, m.Date.Format(time.RFC1123), m.Subject, m.Snippet)
		_, _ = s.Fire(ctx, r, "email from "+m.From, event)
		fired++
		if m.Date.After(cursor) {
			cursor = m.Date
		}
	}
	if cursor.After(r.Cursor) {
		s.remember(ctx, r, func(cur *rm.Responsibility) { cur.Cursor = cursor })
	}
	return nil
}

// pollCalendar fires once for each event starting within the lead time.
func (s *Service) pollCalendar(ctx context.Context, r *rm.Responsibility) error {
	if s.Google == nil || !s.Google.Connected(ctx, r.OwnerID) {
		return errors.New("the person's Google account is not connected")
	}
	lead := time.Duration(r.LeadMinutes) * time.Minute
	if lead <= 0 {
		lead = 30 * time.Minute
	}
	now := s.now().UTC()
	events, err := s.Google.Events(ctx, r.OwnerID, now, now.Add(lead), "")
	if err != nil {
		return err
	}
	var fired []string
	for _, e := range events {
		key := e.ID + "@" + e.Start.UTC().Format(time.RFC3339)
		if seen(r.Seen, key) || !matches(r, e.Summary+" "+e.Location) || len(fired) == maxFiresPerLook {
			continue
		}
		event := fmt.Sprintf("Calendar event %q starts %s (in %s)", e.Summary, e.Start.Format(time.RFC1123), e.Start.Sub(now).Round(time.Minute))
		if e.Location != "" {
			event += "\nWhere: " + e.Location
		}
		if e.Link != "" {
			event += "\n" + e.Link
		}
		_, _ = s.Fire(ctx, r, "calendar", event)
		fired = append(fired, key)
	}
	if len(fired) > 0 {
		s.remember(ctx, r, func(cur *rm.Responsibility) { cur.Seen = addSeen(cur.Seen, fired...) })
	}
	return nil
}

// feed is the part of an RSS or Atom document a poll reads.
type feed struct {
	Channel struct {
		Items []struct {
			Title       string `xml:"title"`
			Link        string `xml:"link"`
			GUID        string `xml:"guid"`
			Description string `xml:"description"`
			PubDate     string `xml:"pubDate"`
		} `xml:"item"`
	} `xml:"channel"`
	Entries []struct {
		Title   string `xml:"title"`
		ID      string `xml:"id"`
		Summary string `xml:"summary"`
		Content string `xml:"content"`
		Updated string `xml:"updated"`
		Link    struct {
			Href string `xml:"href,attr"`
		} `xml:"link"`
	} `xml:"entry"`
}

type feedItem struct{ id, title, link, text string }

var tags = regexp.MustCompile(`<[^>]+>`)

func parseFeed(raw []byte) ([]feedItem, error) {
	var f feed
	if err := xml.Unmarshal(raw, &f); err != nil {
		return nil, errs.InvalidArgument("not an RSS or Atom feed")
	}
	var out []feedItem
	for _, it := range f.Channel.Items {
		id := it.GUID
		if id == "" {
			id = it.Link + "|" + it.Title
		}
		out = append(out, feedItem{id, it.Title, it.Link, tags.ReplaceAllString(it.Description, "")})
	}
	for _, e := range f.Entries {
		id := e.ID
		if id == "" {
			id = e.Link.Href + "|" + e.Title
		}
		text := e.Summary
		if text == "" {
			text = e.Content
		}
		out = append(out, feedItem{id, e.Title, e.Link.Href, tags.ReplaceAllString(text, "")})
	}
	return out, nil
}

// pollFeed fires for new items of an RSS or Atom feed. The first look only
// learns the items already there.
func (s *Service) pollFeed(ctx context.Context, r *rm.Responsibility) error {
	raw, err := s.fetch(ctx, r.URL, "")
	if err != nil {
		return err
	}
	items, err := parseFeed(raw)
	if err != nil {
		return err
	}
	first := len(r.Seen) == 0 && r.Fingerprint == ""
	var ids []string
	fired := 0
	for _, it := range items {
		if seen(r.Seen, it.id) {
			continue
		}
		ids = append(ids, it.id)
		if first || !matches(r, it.title+" "+it.text) || fired == maxFiresPerLook {
			continue
		}
		_, _ = s.Fire(ctx, r, "feed "+r.URL, fmt.Sprintf("New in the feed: %s\n%s\n%s", it.title, it.link, clip(it.text, 2000)))
		fired++
	}
	s.remember(ctx, r, func(cur *rm.Responsibility) {
		cur.Seen = addSeen(cur.Seen, ids...)
		cur.Fingerprint = "looked"
	})
	return nil
}

// valueAt reads a dotted path (data.items.0.status) in a JSON document.
func valueAt(doc any, path string) any {
	if path == "" {
		return doc
	}
	cur := doc
	for _, part := range strings.Split(path, ".") {
		switch v := cur.(type) {
		case map[string]any:
			cur = v[part]
		case []any:
			var i int
			if _, err := fmt.Sscanf(part, "%d", &i); err != nil || i < 0 || i >= len(v) {
				return nil
			}
			cur = v[i]
		default:
			return nil
		}
	}
	return cur
}

// changed compares an answer with the last one: it fires on a change (once
// a first answer is known) when the new answer matches the keyword.
func (s *Service) changed(ctx context.Context, r *rm.Responsibility, source, answer string) {
	sum := sha256.Sum256([]byte(answer))
	fp := hex.EncodeToString(sum[:])
	if fp == r.Fingerprint {
		return
	}
	if r.Fingerprint != "" && matches(r, answer) {
		_, _ = s.Fire(ctx, r, source, "The answer changed. It is now:\n"+clip(answer, 5000))
	}
	s.remember(ctx, r, func(cur *rm.Responsibility) { cur.Fingerprint = fp })
}

// pollAPI fires when an API's answer (or one value in its JSON) changes.
func (s *Service) pollAPI(ctx context.Context, r *rm.Responsibility) error {
	token := ""
	if r.Secret != "" {
		t, err := s.secret(r)
		if err != nil {
			return err
		}
		token = t
	}
	raw, err := s.fetch(ctx, r.URL, token)
	if err != nil {
		return err
	}
	answer := string(raw)
	if r.Path != "" {
		var doc any
		if err := json.Unmarshal(raw, &doc); err != nil {
			return errs.InvalidArgument("the answer is not JSON, so it has no value " + r.Path)
		}
		b, _ := json.Marshal(valueAt(doc, r.Path))
		answer = string(b)
	}
	s.changed(ctx, r, "api "+r.URL, answer)
	return nil
}

// pollApp fires when a read-only function of an app answers differently.
// It is called as the person, with nobody watching, so it must only read.
func (s *Service) pollApp(ctx context.Context, r *rm.Responsibility) error {
	if s.Apps == nil {
		return errors.New("apps are not available")
	}
	owner, err := identity.Parse(r.OwnerID)
	if err != nil {
		return err
	}
	ro, err := s.Apps.ReadOnly(ctx, owner, r.SpaceID, r.App, r.Function)
	if err != nil {
		return err
	}
	if !ro {
		return errs.Permission(r.Function + " may change something; only functions that read are checked on their own")
	}
	args := map[string]any{}
	if r.Args != "" {
		_ = json.Unmarshal([]byte(r.Args), &args)
	}
	answer, err := s.Apps.Call(ctx, owner, r.SpaceID, r.App, r.Function, args)
	if err != nil {
		return err
	}
	s.changed(ctx, r, "app "+r.Function, answer)
	return nil
}

// readName reports a function named for reading (get_, list_, search_…).
func readName(name string) bool {
	n := strings.ToLower(name)
	for _, p := range []string{"get", "list", "search", "read", "fetch", "find", "query", "lookup", "status", "show", "view", "describe", "count", "check"} {
		if n == p || strings.HasPrefix(n, p+"_") || strings.HasPrefix(n, p+"-") {
			return true
		}
	}
	return false
}

// fetchLimit bounds what a feed or API may send.
const fetchLimit = 2 << 20

// fetch GETs a feed or an API.
func (s *Service) fetch(ctx context.Context, url, token string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, errs.InvalidArgument("invalid URL")
	}
	req.Header.Set("User-Agent", "Aseman-Responsibilities/1.0")
	req.Header.Set("Accept", "application/json, application/rss+xml, application/atom+xml, text/xml, */*")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%s answered %d", url, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, fetchLimit))
}

// cgnat is the shared address space carriers and some clouds use inside.
var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// publicIP reports an address on the public internet: not loopback,
// private, link-local (cloud metadata), shared or unspecified.
func publicIP(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() ||
		egress.BlockedIP(ip) || cgnat.Contains(ip))
}

// publicClient reaches public addresses only: a responsibility's URL is the
// person's to choose, so it must not reach the node's own network (the
// database, the metadata service, other containers). A node whose feeds and
// APIs are internal sets ASEMAN_RESPONSIBILITIES_ALLOW_PRIVATE=1.
func publicClient() *http.Client {
	dialer := &net.Dialer{Timeout: 10 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		if ip := net.ParseIP(host); ip == nil || (!publicIP(ip) && os.Getenv("ASEMAN_RESPONSIBILITIES_ALLOW_PRIVATE") != "1") {
			return errors.New("that address is not public")
		}
		return nil
	}}
	return &http.Client{Timeout: 25 * time.Second, Transport: &http.Transport{DialContext: dialer.DialContext,
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 15 * time.Second},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			return nil
		}}
}
