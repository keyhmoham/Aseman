package channels

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
)

// AvailableTools offers posting where the person linked their identity (and
// the node set the provider up). Every post asks the person first: the gate
// classifies these as sends.
func (s *Service) AvailableTools(ctx context.Context, actor, space string) ([]string, error) {
	id, err := parseID(actor)
	if err != nil {
		return []string{}, nil
	}
	rows, err := s.Bindings(ctx, id)
	if err != nil {
		return []string{}, nil
	}
	tool := map[string]string{cm.Slack: "slack_post", cm.Teams: "teams_post", cm.Twilio: "sms_send"}
	out := []string{}
	seen := map[string]bool{}
	for _, b := range rows {
		if st, err := s.settings(ctx, b.Provider); err == nil && st.Enabled && !seen[b.Provider] {
			seen[b.Provider] = true
			out = append(out, tool[b.Provider])
		}
	}
	return out, nil
}

// AgentTool serves slack_post, teams_post and sms_send.
func (s *Service) AgentTool(ctx context.Context, call gate.ToolCall) (string, error) {
	var in struct {
		Channel      string `json:"channel"`
		Conversation string `json:"conversation"`
		Text         string `json:"text"`
		ThreadTS     string `json:"thread_ts"`
		To           string `json:"to"`
	}
	_ = json.Unmarshal([]byte(call.Args), &in)
	if strings.TrimSpace(in.Text) == "" {
		return "", errs.InvalidArgument("text is required")
	}
	actor, err := parseID(call.ActorID)
	if err != nil {
		return "", errs.Permission("posting is for a person")
	}
	rows, err := s.Bindings(ctx, actor)
	if err != nil {
		return "", err
	}
	find := func(provider string) *cm.Binding {
		for i := range rows {
			if rows[i].Provider == provider {
				return &rows[i]
			}
		}
		return nil
	}
	switch call.Tool {
	case "slack_post":
		b := find(cm.Slack)
		if b == nil {
			return "", errs.Permission("the person has not linked Slack")
		}
		channel := strings.TrimSpace(in.Channel)
		if channel == "" {
			channel = b.Conversation
		}
		if err := s.slackPost(ctx, channel, in.Text, in.ThreadTS, nil); err != nil {
			return "", err
		}
		return "Posted in Slack.", nil
	case "teams_post":
		b := find(cm.Teams)
		if b == nil {
			return "", errs.Permission("the person has not linked Teams")
		}
		target := *b
		if c := strings.TrimSpace(in.Conversation); c != "" {
			target.Conversation = c
		}
		if err := s.teamsSend(ctx, &target, map[string]any{"type": "message", "text": in.Text}); err != nil {
			return "", err
		}
		return "Posted in Teams.", nil
	case "sms_send":
		if find(cm.Twilio) == nil {
			return "", errs.Permission("the person has not linked a phone")
		}
		if strings.TrimSpace(in.To) == "" {
			return "", errs.InvalidArgument("to is required")
		}
		if err := s.smsSend(ctx, in.To, in.Text); err != nil {
			return "", err
		}
		return "Sent the text to " + in.To + ".", nil
	}
	return "", errs.NotFound("tool " + call.Tool)
}
