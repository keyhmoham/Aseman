package google

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// Event is one calendar event.
type Event struct {
	ID        string    `json:"id"`
	Summary   string    `json:"summary"`
	Start     time.Time `json:"start"`
	End       time.Time `json:"end"`
	AllDay    bool      `json:"all_day,omitempty"`
	Location  string    `json:"location,omitempty"`
	Organizer string    `json:"organizer,omitempty"`
	Attendees []string  `json:"attendees,omitempty"`
	Link      string    `json:"link,omitempty"`
	Status    string    `json:"status,omitempty"`
}

type gEvent struct {
	ID        string `json:"id"`
	Summary   string `json:"summary"`
	Location  string `json:"location"`
	Status    string `json:"status"`
	HTMLLink  string `json:"htmlLink"`
	Start     gTime  `json:"start"`
	End       gTime  `json:"end"`
	Organizer struct {
		Email string `json:"email"`
	} `json:"organizer"`
	Attendees []struct {
		Email string `json:"email"`
	} `json:"attendees"`
}

type gTime struct {
	DateTime string `json:"dateTime,omitempty"`
	Date     string `json:"date,omitempty"`
	TimeZone string `json:"timeZone,omitempty"`
}

func (t gTime) parse() (time.Time, bool) {
	if t.DateTime != "" {
		v, err := time.Parse(time.RFC3339, t.DateTime)
		return v, err == nil
	}
	return time.Time{}, false
}

// DayBounds is the start and end of the day containing at, in a timezone.
func DayBounds(at time.Time, tz string) (time.Time, time.Time) {
	loc, err := time.LoadLocation(strings.TrimSpace(tz))
	if err != nil || strings.TrimSpace(tz) == "" {
		loc = time.UTC
	}
	local := at.In(loc)
	start := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
	return start, start.Add(24 * time.Hour)
}

// Events lists the person's primary calendar between from and to.
func (s *Service) Events(ctx context.Context, accountID string, from, to time.Time, query string) ([]Event, error) {
	if !to.After(from) {
		return nil, errs.InvalidArgument("the end must be after the start")
	}
	q := url.Values{"timeMin": {from.UTC().Format(time.RFC3339)}, "timeMax": {to.UTC().Format(time.RFC3339)},
		"singleEvents": {"true"}, "orderBy": {"startTime"}, "maxResults": {"100"}}
	if query != "" {
		q.Set("q", query)
	}
	var out struct {
		Items []gEvent `json:"items"`
	}
	if err := s.api(ctx, accountID, http.MethodGet, s.endpoints().Calendar+"/calendars/primary/events?"+q.Encode(), nil, &out); err != nil {
		return nil, err
	}
	events := make([]Event, 0, len(out.Items))
	for _, it := range out.Items {
		if it.Status == "cancelled" {
			continue
		}
		e := Event{ID: it.ID, Summary: it.Summary, Location: it.Location, Organizer: it.Organizer.Email, Link: it.HTMLLink, Status: it.Status}
		var timed bool
		e.Start, timed = it.Start.parse()
		e.End, _ = it.End.parse()
		if !timed {
			e.AllDay = true
			if d, err := time.Parse("2006-01-02", it.Start.Date); err == nil {
				e.Start = d
			}
			if d, err := time.Parse("2006-01-02", it.End.Date); err == nil {
				e.End = d
			}
		}
		for _, a := range it.Attendees {
			e.Attendees = append(e.Attendees, a.Email)
		}
		events = append(events, e)
	}
	return events, nil
}

// NewEvent is an event to create.
type NewEvent struct {
	Summary     string   `json:"summary"`
	Start       string   `json:"start"`
	End         string   `json:"end"`
	Attendees   []string `json:"attendees,omitempty"`
	Description string   `json:"description,omitempty"`
	Location    string   `json:"location,omitempty"`
}

// CreateEvent puts an event on the person's calendar and invites its
// attendees. The governance gate asked the person before this is reached.
func (s *Service) CreateEvent(ctx context.Context, accountID string, e NewEvent) (*Event, error) {
	start, err := time.Parse(time.RFC3339, e.Start)
	if err != nil {
		return nil, errs.InvalidArgument("start must be an RFC 3339 time")
	}
	end, err := time.Parse(time.RFC3339, e.End)
	if err != nil || !end.After(start) {
		return nil, errs.InvalidArgument("end must be an RFC 3339 time after start")
	}
	if strings.TrimSpace(e.Summary) == "" {
		return nil, errs.InvalidArgument("an event needs a summary")
	}
	body := map[string]any{"summary": e.Summary, "description": e.Description, "location": e.Location,
		"start": gTime{DateTime: start.Format(time.RFC3339)}, "end": gTime{DateTime: end.Format(time.RFC3339)}}
	var attendees []map[string]string
	for _, a := range e.Attendees {
		if a = strings.TrimSpace(a); a != "" {
			attendees = append(attendees, map[string]string{"email": a})
		}
	}
	if len(attendees) > 0 {
		body["attendees"] = attendees
	}
	var out gEvent
	if err := s.api(ctx, accountID, http.MethodPost, s.endpoints().Calendar+"/calendars/primary/events?sendUpdates=all", body, &out); err != nil {
		return nil, err
	}
	return &Event{ID: out.ID, Summary: out.Summary, Start: start, End: end, Link: out.HTMLLink, Attendees: e.Attendees}, nil
}
