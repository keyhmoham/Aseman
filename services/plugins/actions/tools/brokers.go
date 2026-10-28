package tools

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// Connector brokers: services that put many apps (Gmail, Slack, GitHub,
// Salesforce, ...) behind one MCP server, holding each person's accounts on
// their side. An administrator adds a broker once with the node's API key;
// every call then names the person it is for ({{actor}} below), so each
// person connects and uses their own accounts at the broker. Like any app, a
// broker is granted to agents through their allowed tools, and every call
// passes the governance gate (its tools' read-only and destructive hints
// decide whether they ask first).

// actorPlaceholder in a shared server's header is the calling person's id.
const actorPlaceholder = "{{actor}}"

func actorHeader(value string, actor identity.ID) string {
	if !strings.Contains(value, actorPlaceholder) {
		return value
	}
	return strings.ReplaceAll(value, actorPlaceholder, actor.String())
}

// broker is a preset an administrator fills with a key and the MCP address
// from the broker's dashboard.
type broker struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Site        string            `json:"site"`
	Description string            `json:"description"`
	URLHint     string            `json:"url_hint"`
	Headers     map[string]string `json:"headers"`
	Docs        string            `json:"docs"`
	// Connect is where each person connects their own accounts.
	Connect string `json:"connect"`
}

var brokers = []broker{
	{ID: "composio", Name: "Composio", Site: "composio.dev",
		Description: "Hundreds of apps (Gmail, Slack, GitHub, Notion, HubSpot, ...) through one MCP server; each person connects their own accounts at Composio.",
		URLHint:     "https://backend.composio.dev/v3/mcp/<server-id>/mcp",
		Headers:     map[string]string{"x-api-key": "{{key}}", "x-user-id": actorPlaceholder},
		Docs:        "https://docs.composio.dev", Connect: "https://app.composio.dev"},
	{ID: "arcade", Name: "Arcade", Site: "arcade.dev",
		Description: "Authenticated tools for Google, Microsoft, Slack, GitHub and more through Arcade's MCP gateway; each person authorizes their own accounts at Arcade.",
		URLHint:     "https://api.arcade.dev/mcp/<gateway-slug>",
		Headers:     map[string]string{"Authorization": "Bearer {{key}}", "Arcade-User-ID": actorPlaceholder},
		Docs:        "https://docs.arcade.dev", Connect: "https://api.arcade.dev/dashboard"},
}

func brokerActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "tools", Name: "broker_presets", Summary: "Admin: the connector brokers that can be added (Composio, Arcade)", Handler: s.brokerPresets},
		helper.Action{Namespace: "tools", Name: "broker_add", Summary: "Admin: add a connector broker with the node's API key and its MCP address", Handler: s.brokerAdd},
	}
}

func (s *Service) brokerPresets(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"brokers": brokers})
}

func (s *Service) brokerAdd(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Broker string `json:"broker"`
		URL    string `json:"url"`
		Key    string `json:"api_key"`
		Name   string `json:"name,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	var preset *broker
	for i := range brokers {
		if brokers[i].ID == in.Broker {
			preset = &brokers[i]
		}
	}
	if preset == nil {
		return nil, errs.InvalidArgument("unknown broker " + in.Broker)
	}
	if strings.TrimSpace(in.Key) == "" {
		return nil, errs.InvalidArgument("the broker's API key is required")
	}
	headers := map[string]string{}
	for k, v := range preset.Headers {
		headers[k] = strings.ReplaceAll(v, "{{key}}", strings.TrimSpace(in.Key))
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		name = preset.Name
	}
	out, err := s.registerMCP(ctx, req, mcpInput{Name: name, URL: strings.TrimSpace(in.URL), Headers: headers, Listed: true,
		Descriptor: map[string]any{"description": preset.Description, "site": preset.Site, "broker": preset.ID,
			"connect": map[string]any{"url": preset.Connect, "label": "your accounts at " + preset.Name}}})
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}
