package responsibilities

import (
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
)

// What fires a responsibility, in one catalog: each trigger says how it
// arrives (a signed hook, a poll, the clock), which fields it takes and how
// its source is connected. The app builds its form from it
// (responsibilities.triggers); Create checks against it.

// Deliveries.
const (
	DeliveryHook     = "hook"
	DeliveryPoll     = "poll"
	DeliverySchedule = "schedule"
)

// Field is one setting a trigger takes.
type Field struct {
	Name     string `json:"name"`
	Label    string `json:"label"`
	Help     string `json:"help,omitempty"`
	Kind     string `json:"kind"` // text, list, number, time, url, json, app, secret
	Required bool   `json:"required,omitempty"`
}

// Trigger is one kind of event a responsibility reacts to.
type Trigger struct {
	ID       string  `json:"id"`
	Label    string  `json:"label"`
	Group    string  `json:"group"`
	Delivery string  `json:"delivery"`
	Help     string  `json:"help"`
	Fields   []Field `json:"fields"`
	// Setup says how to point the source at the responsibility's URL and
	// which secret it signs with (hooks).
	Setup string `json:"setup,omitempty"`
	// OneOf names fields of which at least one must be set.
	OneOf []string `json:"one_of,omitempty"`
}

var (
	fKeyword = Field{Name: "keyword", Label: "Contains", Help: "Only events whose text contains this.", Kind: "text"}
	fEvents  = func(help string) Field {
		return Field{Name: "events", Label: "Event types", Help: help, Kind: "list"}
	}
	fSecret = func(help string) Field {
		return Field{Name: "secret", Label: "Signing secret", Help: help, Kind: "secret", Required: true}
	}
	fInterval = func(def string) Field {
		return Field{Name: "interval_minutes", Label: "Check every (minutes)", Help: "Default " + def + ".", Kind: "number"}
	}
)

// Triggers is the catalog.
var Triggers = []Trigger{
	// Mail and calendar.
	{ID: rm.TriggerEmail, Label: "An email arrives", Group: "Mail and calendar", Delivery: DeliveryPoll,
		Help: "New mail in the person's connected Gmail (the Google app) that matches.",
		Fields: []Field{{Name: "from", Label: "From contains", Kind: "text"}, {Name: "subject", Label: "Subject contains", Kind: "text"},
			{Name: "label", Label: "Gmail label", Kind: "text"}},
		OneOf: []string{"from", "subject", "label"}},
	{ID: rm.TriggerCalendar, Label: "A calendar event is coming up", Group: "Mail and calendar", Delivery: DeliveryPoll,
		Help: "An event on the person's Google Calendar starts soon: prepare for it.",
		Fields: []Field{{Name: "lead_minutes", Label: "Minutes before", Help: "Default 30.", Kind: "number"}, fKeyword}},
	// Code and work tracking.
	{ID: rm.TriggerGitHub, Label: "A GitHub event", Group: "Code and work tracking", Delivery: DeliveryHook,
		Help: "Issues, pull requests, comments, pushes, releases.",
		Fields: []Field{{Name: "repo", Label: "Repository", Help: "owner/name; empty for any.", Kind: "text"},
			fEvents("issues, pull_request, issue_comment, push, release…; empty for any."), {Name: "action", Label: "Action", Help: "opened, labeled, closed…", Kind: "text"}},
		Setup: "Repository → Settings → Webhooks: payload URL below, content type application/json, the secret below."},
	{ID: rm.TriggerGitLab, Label: "A GitLab event", Group: "Code and work tracking", Delivery: DeliveryHook,
		Help: "Issues, merge requests, comments, pushes, pipelines.",
		Fields: []Field{{Name: "repo", Label: "Project", Help: "group/project; empty for any.", Kind: "text"},
			fEvents("Issue Hook, Merge Request Hook, Note Hook, Push Hook, Pipeline Hook…"), {Name: "action", Label: "Action", Help: "open, merge, close…", Kind: "text"}},
		Setup: "Project → Settings → Webhooks: the URL below and the secret below as its secret token."},
	{ID: rm.TriggerLinear, Label: "A Linear event", Group: "Code and work tracking", Delivery: DeliveryHook,
		Help: "Issues, comments, projects and cycles.",
		Fields: []Field{fEvents("Issue, Comment, Project…; empty for any."), {Name: "action", Label: "Action", Help: "create, update, remove.", Kind: "text"}, fKeyword,
			fSecret("The webhook's signing secret Linear shows.")},
		Setup: "Linear → Settings → API → Webhooks: the URL below; paste Linear's signing secret here."},
	{ID: rm.TriggerJira, Label: "A Jira event", Group: "Code and work tracking", Delivery: DeliveryHook,
		Help: "Issues created, updated or commented on.",
		Fields: []Field{{Name: "repo", Label: "Project key", Help: "e.g. OPS; empty for any.", Kind: "text"},
			fEvents("jira:issue_created, jira:issue_updated, comment_created…"), fKeyword},
		Setup: "Jira → System → WebHooks: the URL below and the secret below."},
	// Chat and messages.
	{ID: rm.TriggerSlack, Label: "A Slack message", Group: "Chat and messages", Delivery: DeliveryHook,
		Help: "A message or mention in a channel the Slack app is in.",
		Fields: []Field{{Name: "channel", Label: "Channel ID", Kind: "text"}, fKeyword, fSecret("The Slack app's signing secret.")},
		Setup: "Slack app → Event Subscriptions: the URL below; subscribe to message.channels and app_mention."},
	{ID: rm.TriggerTeams, Label: "A Microsoft Teams message", Group: "Chat and messages", Delivery: DeliveryHook,
		Help: "A message that @mentions an outgoing webhook in a Teams channel.",
		Fields: []Field{fKeyword, fSecret("The security token Teams shows when the outgoing webhook is created.")},
		Setup: "Teams channel → Manage team → Apps → Create an outgoing webhook: the URL below; paste its token here."},
	{ID: rm.TriggerSMS, Label: "A text message (SMS)", Group: "Chat and messages", Delivery: DeliveryHook,
		Help: "A text to a Twilio number.",
		Fields: []Field{{Name: "from", Label: "From number", Help: "E.164; empty for any.", Kind: "text"}, fKeyword, fSecret("The Twilio account's auth token.")},
		Setup: "Twilio → the number → Messaging: \"A message comes in\" webhook (HTTP POST) to the URL below."},
	// Payments and commerce.
	{ID: rm.TriggerStripe, Label: "A Stripe event", Group: "Payments and commerce", Delivery: DeliveryHook,
		Help: "Payments, refunds, disputes, subscriptions, invoices.",
		Fields: []Field{fEvents("payment_intent.succeeded, charge.dispute.created, invoice.payment_failed…; empty for any."), fSecret("The endpoint's signing secret (whsec_…).")},
		Setup: "Stripe → Developers → Webhooks → Add endpoint: the URL below; paste its signing secret here."},
	{ID: rm.TriggerShopify, Label: "A Shopify event", Group: "Payments and commerce", Delivery: DeliveryHook,
		Help: "Orders, customers, products, fulfillments.",
		Fields: []Field{fEvents("orders/create, orders/paid, customers/create…; empty for any."), fSecret("The app's client secret (or the store's webhook signing secret).")},
		Setup: "Shopify admin → Settings → Notifications → Webhooks: JSON, the URL below."},
	// Web, APIs and apps.
	{ID: rm.TriggerFeed, Label: "A new item in a feed", Group: "Web, APIs and apps", Delivery: DeliveryPoll,
		Help: "A new post in an RSS or Atom feed (a blog, a changelog, a status page).",
		Fields: []Field{{Name: "url", Label: "Feed URL", Kind: "url", Required: true}, fKeyword, fInterval("15")}},
	{ID: rm.TriggerAPI, Label: "An API's answer changes", Group: "Web, APIs and apps", Delivery: DeliveryPoll,
		Help: "Any HTTP(S) URL is checked; it fires when its answer (or one value in its JSON) changes.",
		Fields: []Field{{Name: "url", Label: "URL", Kind: "url", Required: true},
			{Name: "path", Label: "JSON value", Help: "A dotted path like data.status; empty for the whole answer.", Kind: "text"},
			fKeyword, {Name: "secret", Label: "Bearer token", Help: "Sent as Authorization: Bearer; optional.", Kind: "secret"}, fInterval("15")}},
	{ID: rm.TriggerApp, Label: "An app's answer changes", Group: "Web, APIs and apps", Delivery: DeliveryPoll,
		Help: "A read-only function of an app in the project is called as the person; it fires when the answer changes.",
		Fields: []Field{{Name: "app", Label: "App", Kind: "app", Required: true}, {Name: "function", Label: "Function", Kind: "text", Required: true},
			{Name: "args", Label: "Arguments (JSON)", Kind: "json"}, fKeyword, fInterval("15")}},
	{ID: rm.TriggerWebhook, Label: "A signed webhook", Group: "Web, APIs and apps", Delivery: DeliveryHook,
		Help: "Anything that can POST: X-Aseman-Timestamp and X-Aseman-Signature (sha256 HMAC of \"<timestamp>.<body>\").",
		Fields: []Field{fKeyword},
		Setup: "POST JSON to the URL below, signed with the secret below."},
	// Time.
	{ID: rm.TriggerSchedule, Label: "On a schedule", Group: "Time", Delivery: DeliverySchedule,
		Help: "Every few minutes or hours, or every day at a time.",
		Fields: []Field{{Name: "interval_minutes", Label: "Every (minutes)", Kind: "number"}, {Name: "at", Label: "Or daily at (HH:MM)", Kind: "time"},
			{Name: "timezone", Label: "Time zone", Help: "e.g. Europe/Berlin; default UTC.", Kind: "text"}},
		OneOf: []string{"interval_minutes", "at"}},
}

// TriggerFor is a trigger of the catalog.
func TriggerFor(id string) (Trigger, bool) {
	for _, t := range Triggers {
		if t.ID == id {
			return t, true
		}
	}
	return Trigger{}, false
}

var dailyTime = regexp.MustCompile(`^([01]\d|2[0-3]):[0-5]\d$`)

// value is an Input's setting by field name.
func (in Input) value(name string) string {
	switch name {
	case "from":
		return in.From
	case "subject":
		return in.Subject
	case "label":
		return in.Label
	case "repo":
		return in.Repo
	case "events":
		return strings.Join(in.Events, ",")
	case "action":
		return in.Action
	case "channel":
		return in.Channel
	case "keyword":
		return in.Keyword
	case "url":
		return in.URL
	case "path":
		return in.Path
	case "app":
		return in.App
	case "function":
		return in.Function
	case "args":
		return in.Args
	case "at":
		return in.At
	case "timezone":
		return in.Timezone
	case "secret":
		return in.Secret
	case "interval_minutes":
		if in.IntervalMinutes > 0 {
			return "set"
		}
	case "lead_minutes":
		if in.LeadMinutes > 0 {
			return "set"
		}
	}
	return ""
}

// check validates an Input against its trigger.
func (t Trigger) check(in Input) error {
	for _, f := range t.Fields {
		if f.Required && strings.TrimSpace(in.value(f.Name)) == "" {
			return errs.InvalidArgument(t.Label + " needs " + strings.ToLower(f.Label))
		}
	}
	if len(t.OneOf) > 0 {
		set := false
		for _, name := range t.OneOf {
			set = set || strings.TrimSpace(in.value(name)) != ""
		}
		if !set {
			return errs.InvalidArgument(t.Label + " needs one of " + strings.Join(t.OneOf, ", "))
		}
	}
	if in.URL != "" {
		u, err := url.Parse(in.URL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil {
			return errs.InvalidArgument("the URL must be http(s), without credentials in it")
		}
	}
	if in.At != "" && !dailyTime.MatchString(in.At) {
		return errs.InvalidArgument("a daily time is HH:MM")
	}
	if in.Timezone != "" {
		if _, err := time.LoadLocation(in.Timezone); err != nil {
			return errs.InvalidArgument("unknown time zone " + in.Timezone)
		}
	}
	if in.IntervalMinutes < 0 || in.LeadMinutes < 0 {
		return errs.InvalidArgument("minutes cannot be negative")
	}
	return nil
}

// interval is how often a poll or schedule runs.
func interval(r *rm.Responsibility) time.Duration {
	min := map[string]int64{rm.TriggerEmail: 2, rm.TriggerCalendar: 5, rm.TriggerFeed: 5, rm.TriggerAPI: 5, rm.TriggerApp: 5, rm.TriggerSchedule: 5}[r.Trigger]
	def := map[string]int64{rm.TriggerEmail: 2, rm.TriggerCalendar: 5, rm.TriggerFeed: 15, rm.TriggerAPI: 15, rm.TriggerApp: 15, rm.TriggerSchedule: 60}[r.Trigger]
	m := r.IntervalMinutes
	if m == 0 {
		m = def
	}
	if m < min {
		m = min
	}
	return time.Duration(m) * time.Minute
}

// nextRun is when a poll or schedule is next due after [from].
func nextRun(r *rm.Responsibility, from time.Time) time.Time {
	if r.Trigger == rm.TriggerSchedule && r.At != "" {
		loc := time.UTC
		if l, err := time.LoadLocation(r.Timezone); err == nil && r.Timezone != "" {
			loc = l
		}
		t, _ := time.ParseInLocation("15:04", r.At, loc)
		local := from.In(loc)
		next := time.Date(local.Year(), local.Month(), local.Day(), t.Hour(), t.Minute(), 0, 0, loc)
		if !next.After(from) {
			next = next.AddDate(0, 0, 1)
		}
		return next.UTC()
	}
	return from.Add(interval(r)).UTC()
}
