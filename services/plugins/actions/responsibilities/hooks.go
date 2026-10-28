package responsibilities

import (
	"context"
	"crypto/hmac"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// HookPath is where providers deliver a responsibility's events.
const HookPath = "/hooks/v1/responsibilities"

// replayWindow bounds how old a signed delivery may be.
const replayWindow = 5 * time.Minute

func header(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func reply(status int, v any) *network.Response {
	raw, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: raw}
}

// serveHook verifies one delivery and fires its responsibility. Deliveries
// are answered at once; the run happens after, so providers do not retry.
func (s *Service) serveHook(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	_ = json.Unmarshal([]byte(header(req.Header, "x-route-params")), &params)
	id, err := identity.Parse(params["id"])
	if err != nil {
		return reply(http.StatusNotFound, map[string]string{"error": "not found"}), nil
	}
	var r rm.Responsibility
	if err := s.R.Get(ctx, "responsibilities", id, &r); err != nil || r.Trigger == rm.TriggerEmail {
		return reply(http.StatusNotFound, map[string]string{"error": "not found"}), nil
	}
	secret, err := s.secret(&r)
	if err != nil {
		return reply(http.StatusInternalServerError, map[string]string{"error": "unavailable"}), nil
	}
	var source, event string
	var ok bool
	switch r.Trigger {
	case rm.TriggerGitHub:
		source, event, ok = s.github(&r, secret, req)
	case rm.TriggerSlack:
		var challenge string
		source, event, challenge, ok = s.slack(&r, secret, req)
		if challenge != "" {
			return reply(http.StatusOK, map[string]string{"challenge": challenge}), nil
		}
	case rm.TriggerWebhook:
		source, event, ok = s.webhook(secret, req)
	}
	if !ok {
		return reply(http.StatusUnauthorized, map[string]string{"error": "signature"}), nil
	}
	if event == "" || !r.Enabled {
		return reply(http.StatusOK, map[string]string{"status": "ignored"}), nil
	}
	go func() {
		bg := context.WithoutCancel(ctx)
		if _, err := s.Fire(bg, &r, source, event); err != nil {
			s.L.Warn("responsibility failed", "id", r.ID.String(), "error", err)
		}
	}()
	return reply(http.StatusAccepted, map[string]string{"status": "accepted"}), nil
}

// github verifies X-Hub-Signature-256 and matches the event, repository and
// action. A ping is accepted and does nothing.
func (s *Service) github(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	sig := strings.TrimPrefix(header(req.Header, "X-Hub-Signature-256"), "sha256=")
	if !hmac.Equal([]byte(sig), []byte(hmacHex(secret, req.Body))) {
		return "", "", false
	}
	kind := header(req.Header, "X-GitHub-Event")
	if kind == "ping" {
		return "", "", true
	}
	var p struct {
		Action     string `json:"action"`
		Repository struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
		Sender struct {
			Login string `json:"login"`
		} `json:"sender"`
		Issue *struct {
			Number int    `json:"number"`
			Title  string `json:"title"`
			Body   string `json:"body"`
			URL    string `json:"html_url"`
		} `json:"issue"`
		PullRequest *struct {
			Number int    `json:"number"`
			Title  string `json:"title"`
			Body   string `json:"body"`
			URL    string `json:"html_url"`
		} `json:"pull_request"`
		Comment *struct {
			Body string `json:"body"`
		} `json:"comment"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if r.Repo != "" && !strings.EqualFold(r.Repo, p.Repository.FullName) {
		return "", "", true
	}
	if len(r.Events) > 0 && !contains(r.Events, kind) {
		return "", "", true
	}
	if r.Action != "" && !strings.EqualFold(r.Action, p.Action) {
		return "", "", true
	}
	var b strings.Builder
	fmt.Fprintf(&b, "GitHub %s %s in %s by %s\n", kind, p.Action, p.Repository.FullName, p.Sender.Login)
	if p.Issue != nil {
		fmt.Fprintf(&b, "Issue #%d: %s\n%s\n%s\n", p.Issue.Number, p.Issue.Title, p.Issue.URL, p.Issue.Body)
	}
	if p.PullRequest != nil {
		fmt.Fprintf(&b, "Pull request #%d: %s\n%s\n%s\n", p.PullRequest.Number, p.PullRequest.Title, p.PullRequest.URL, p.PullRequest.Body)
	}
	if p.Comment != nil {
		b.WriteString("Comment: " + p.Comment.Body + "\n")
	}
	return "github " + p.Repository.FullName, b.String(), true
}

// slack verifies Slack's v0 signature within the replay window, answers the
// URL verification, and matches the channel and keyword of a message.
func (s *Service) slack(r *rm.Responsibility, secret string, req *network.Request) (string, string, string, bool) {
	ts := header(req.Header, "X-Slack-Request-Timestamp")
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || absDuration(s.now().Sub(time.Unix(sec, 0))) > replayWindow {
		return "", "", "", false
	}
	sig := strings.TrimPrefix(header(req.Header, "X-Slack-Signature"), "v0=")
	if !hmac.Equal([]byte(sig), []byte(hmacHex(secret, []byte("v0:"+ts+":"), req.Body))) {
		return "", "", "", false
	}
	var p struct {
		Type      string `json:"type"`
		Challenge string `json:"challenge"`
		Event     struct {
			Type    string `json:"type"`
			Channel string `json:"channel"`
			User    string `json:"user"`
			Text    string `json:"text"`
			BotID   string `json:"bot_id"`
			Subtype string `json:"subtype"`
		} `json:"event"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if p.Type == "url_verification" {
		return "", "", p.Challenge, true
	}
	e := p.Event
	if e.BotID != "" || e.Subtype != "" || (e.Type != "message" && e.Type != "app_mention") {
		return "", "", "", true
	}
	if r.Channel != "" && r.Channel != e.Channel {
		return "", "", "", true
	}
	if r.Keyword != "" && !strings.Contains(strings.ToLower(e.Text), strings.ToLower(r.Keyword)) {
		return "", "", "", true
	}
	return "slack message from " + e.User, fmt.Sprintf("Slack message in %s from %s:\n%s", e.Channel, e.User, e.Text), "", true
}

// webhook verifies X-Aseman-Signature: sha256 of "<timestamp>.<body>" with
// the responsibility's secret, X-Aseman-Timestamp within the replay window.
func (s *Service) webhook(secret string, req *network.Request) (string, string, bool) {
	ts := header(req.Header, "X-Aseman-Timestamp")
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || absDuration(s.now().Sub(time.Unix(sec, 0))) > replayWindow {
		return "", "", false
	}
	sig := strings.TrimPrefix(header(req.Header, "X-Aseman-Signature"), "sha256=")
	if !hmac.Equal([]byte(sig), []byte(hmacHex(secret, []byte(ts+"."), req.Body))) {
		return "", "", false
	}
	return "webhook", string(req.Body), true
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if strings.EqualFold(x, v) {
			return true
		}
	}
	return false
}

func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}
