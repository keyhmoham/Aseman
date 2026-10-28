package channels

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/replies"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Slack: the Events API (direct messages and mentions of the app) at
// SlackEventsPath, interactivity (approval buttons, reply chips) at
// SlackActionsPath, both verified with the app's signing secret. Replies go
// out with chat.postMessage and the bot token.
const (
	SlackEventsPath  = "/channels/v1/slack/events"
	SlackActionsPath = "/channels/v1/slack/actions"
)

func headerOf(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func jsonReply(status int, v any) *network.Response {
	raw, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: raw}
}

// slackVerified checks the v0 signature within five minutes.
func (s *Service) slackVerified(secret string, req *network.Request) bool {
	ts := headerOf(req.Header, "X-Slack-Request-Timestamp")
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || secret == "" {
		return false
	}
	if d := s.now().Sub(time.Unix(sec, 0)); d > 5*time.Minute || d < -5*time.Minute {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte("v0:" + ts + ":"))
	mac.Write(req.Body)
	want := "v0=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(want), []byte(headerOf(req.Header, "X-Slack-Signature")))
}

func (s *Service) serveSlackEvents(ctx context.Context, req *network.Request) (*network.Response, error) {
	st, err := s.settings(ctx, cm.Slack)
	if err != nil || !st.Enabled {
		return jsonReply(http.StatusNotFound, map[string]string{"error": "slack is not set up"}), nil
	}
	if !s.slackVerified(st.secret, req) {
		return jsonReply(http.StatusUnauthorized, map[string]string{"error": "signature"}), nil
	}
	var p struct {
		Type      string `json:"type"`
		Challenge string `json:"challenge"`
		TeamID    string `json:"team_id"`
		Event     struct {
			Type        string `json:"type"`
			Channel     string `json:"channel"`
			ChannelType string `json:"channel_type"`
			User        string `json:"user"`
			Text        string `json:"text"`
			TS          string `json:"ts"`
			ThreadTS    string `json:"thread_ts"`
			BotID       string `json:"bot_id"`
			Subtype     string `json:"subtype"`
		} `json:"event"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if p.Type == "url_verification" {
		return jsonReply(http.StatusOK, map[string]string{"challenge": p.Challenge}), nil
	}
	// Slack retries a delivery it did not see answered; the first one ran.
	if headerOf(req.Header, "X-Slack-Retry-Num") != "" {
		return jsonReply(http.StatusOK, map[string]string{"status": "retry ignored"}), nil
	}
	e := p.Event
	if e.BotID != "" || e.Subtype != "" || e.User == "" {
		return jsonReply(http.StatusOK, map[string]string{"status": "ignored"}), nil
	}
	if !(e.Type == "app_mention" || (e.Type == "message" && e.ChannelType == "im")) {
		return jsonReply(http.StatusOK, map[string]string{"status": "ignored"}), nil
	}
	text := strings.TrimSpace(mentionPrefix(e.Text))
	thread := e.ThreadTS
	if thread == "" {
		thread = e.TS
	}
	if code, ok := linkCommand(text); ok {
		msg := s.redeem(ctx, cm.Slack, code, cm.Binding{External: e.User, Workspace: p.TeamID, Conversation: e.Channel})
		_ = s.slackPost(ctx, e.Channel, msg, thread, nil)
		return jsonReply(http.StatusOK, map[string]string{"status": "linked"}), nil
	}
	b, ok := s.binding(ctx, cm.Slack, p.TeamID, e.User)
	if !ok {
		_ = s.slackPost(ctx, e.Channel, "I don't know who you are in Aseman yet. In Aseman, open Settings → Channels → Slack, then send me: link <code>.", thread, nil)
		return jsonReply(http.StatusOK, map[string]string{"status": "unlinked"}), nil
	}
	channel := e.Channel
	s.converse(ctx, b, text, func(ctx context.Context, answer string) {
		body, chips := replies.Parse(answer)
		if err := s.slackPost(ctx, channel, body, thread, chips); err != nil {
			s.L.Warn("slack reply not sent", "error", err)
		}
	})
	return jsonReply(http.StatusOK, map[string]string{"status": "accepted"}), nil
}

// mentionPrefix drops a leading <@U…> mention of the app.
func mentionPrefix(text string) string {
	t := strings.TrimSpace(text)
	if strings.HasPrefix(t, "<@") {
		if i := strings.Index(t, ">"); i > 0 {
			return t[i+1:]
		}
	}
	return t
}

// serveSlackActions answers a button: an approval, or a reply chip.
func (s *Service) serveSlackActions(ctx context.Context, req *network.Request) (*network.Response, error) {
	st, err := s.settings(ctx, cm.Slack)
	if err != nil || !st.Enabled {
		return jsonReply(http.StatusNotFound, map[string]string{"error": "slack is not set up"}), nil
	}
	if !s.slackVerified(st.secret, req) {
		return jsonReply(http.StatusUnauthorized, map[string]string{"error": "signature"}), nil
	}
	form, err := url.ParseQuery(string(req.Body))
	if err != nil {
		return jsonReply(http.StatusBadRequest, map[string]string{"error": "form"}), nil
	}
	var p struct {
		User struct {
			ID string `json:"id"`
		} `json:"user"`
		Team struct {
			ID string `json:"id"`
		} `json:"team"`
		Channel struct {
			ID string `json:"id"`
		} `json:"channel"`
		Message struct {
			TS       string `json:"ts"`
			ThreadTS string `json:"thread_ts"`
		} `json:"message"`
		Actions []struct {
			ActionID string `json:"action_id"`
			Value    string `json:"value"`
		} `json:"actions"`
	}
	if err := json.Unmarshal([]byte(form.Get("payload")), &p); err != nil || len(p.Actions) == 0 {
		return jsonReply(http.StatusBadRequest, map[string]string{"error": "payload"}), nil
	}
	b, ok := s.binding(ctx, cm.Slack, p.Team.ID, p.User.ID)
	if !ok {
		return jsonReply(http.StatusOK, map[string]string{"text": "Link your Slack to Aseman first."}), nil
	}
	a := p.Actions[0]
	switch {
	case strings.HasPrefix(a.ActionID, "approval:"):
		answer := strings.TrimPrefix(a.ActionID, "approval:")
		caller, _ := parseID(b.AccountID)
		text := answerWord(answer) + "."
		if err := s.Governance.Answer(ctx, caller, a.Value, answer); err != nil {
			text = "Couldn't answer: " + err.Error()
		}
		_ = s.slackUpdate(ctx, p.Channel.ID, p.Message.TS, text)
	case strings.HasPrefix(a.ActionID, "reply"):
		thread := p.Message.ThreadTS
		if thread == "" {
			thread = p.Message.TS
		}
		channel := p.Channel.ID
		s.converse(ctx, b, a.Value, func(ctx context.Context, answer string) {
			body, chips := replies.Parse(answer)
			_ = s.slackPost(ctx, channel, body, thread, chips)
		})
	}
	return &network.Response{Status: http.StatusOK}, nil
}

// slackApproval asks in the person's Slack DM, with the three answers.
func (s *Service) slackApproval(ctx context.Context, b *cm.Binding, note gate.ApprovalNote) error {
	blocks := []map[string]any{
		{"type": "section", "text": map[string]string{"type": "mrkdwn", "text": "*Waiting for your approval*\n" + approvalText(note)}},
		{"type": "actions", "elements": []map[string]any{
			{"type": "button", "action_id": "approval:once", "value": note.ID, "style": "primary", "text": map[string]string{"type": "plain_text", "text": "Allow once"}},
			{"type": "button", "action_id": "approval:always", "value": note.ID, "text": map[string]string{"type": "plain_text", "text": "Always allow"}},
			{"type": "button", "action_id": "approval:refuse", "value": note.ID, "style": "danger", "text": map[string]string{"type": "plain_text", "text": "Refuse"}},
		}},
	}
	return s.slackCall(ctx, "chat.postMessage", map[string]any{"channel": b.Conversation, "text": "Waiting for your approval: " + note.Summary, "blocks": blocks})
}

// slackPost writes a message, with reply chips as buttons.
func (s *Service) slackPost(ctx context.Context, channel, text, thread string, chips []string) error {
	body := map[string]any{"channel": channel, "text": clip(text, 39000)}
	if thread != "" {
		body["thread_ts"] = thread
	}
	if len(chips) > 0 {
		var buttons []map[string]any
		for i, c := range chips {
			buttons = append(buttons, map[string]any{"type": "button", "action_id": "reply:" + strconv.Itoa(i), "value": c,
				"text": map[string]string{"type": "plain_text", "text": c}})
			if i == 0 {
				buttons[i]["style"] = "primary"
			}
		}
		body["blocks"] = []map[string]any{
			{"type": "section", "text": map[string]string{"type": "mrkdwn", "text": clip(text, 2900)}},
			{"type": "actions", "elements": buttons},
		}
	}
	return s.slackCall(ctx, "chat.postMessage", body)
}

func (s *Service) slackUpdate(ctx context.Context, channel, ts, text string) error {
	return s.slackCall(ctx, "chat.update", map[string]any{"channel": channel, "ts": ts, "text": text, "blocks": []any{}})
}

func (s *Service) slackCall(ctx context.Context, method string, body map[string]any) error {
	st, err := s.settings(ctx, cm.Slack)
	if err != nil {
		return err
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.SlackAPI+"/"+method, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("Authorization", "Bearer "+st.token)
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "slack")
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if json.Unmarshal(data, &out) != nil || !out.OK {
		return errs.New(errs.CodeUnavailable, "slack "+method+": "+out.Error)
	}
	return nil
}
