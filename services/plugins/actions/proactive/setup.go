package proactive

import (
	"context"
	"strconv"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	llmmodels "github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SetupItem is one line of a person's setup checklist: what Aseman's
// proactive work depends on, each Ready, Not checked or Needs setup from the
// real answer, with how to fix it. Onboarding ends on it; Settings → Setup
// opens it again.
type SetupItem struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Status   string `json:"status"` // ready, not_checked, needs_setup
	Detail   string `json:"detail"`
	Fix      string `json:"fix,omitempty"`
	Optional bool   `json:"optional,omitempty"`
}

// Setup checks what the person's assistant depends on. notifications is
// what the device says of its permission ("granted", "denied" or "").
func (s *Service) Setup(ctx context.Context, owner identity.ID, notifications string) []SetupItem {
	var out []SetupItem
	add := func(i SetupItem) { out = append(out, i) }

	// A model the node can run agents on.
	var providers []llmmodels.Provider
	ready := false
	if s.R.List(ctx, "llm_providers", database.Filter{Equal: map[string]any{"enabled": true}}, &providers) == nil {
		for _, p := range providers {
			ready = ready || strings.TrimSpace(p.APIKey) != ""
		}
	}
	if ready {
		add(SetupItem{ID: "model", Label: "A model to work with", Status: "ready", Detail: "The node has a model provider with a key."})
	} else {
		add(SetupItem{ID: "model", Label: "A model to work with", Status: "needs_setup", Detail: "No model provider has a key: agents cannot run.", Fix: "An administrator adds one under Admin → Providers."})
	}

	// Google: offered by the node, connected by the person.
	offered := false
	var settings []struct {
		Enabled bool `json:"enabled"`
	}
	if s.R.List(ctx, "google_settings", database.Filter{Limit: 1}, &settings) == nil && len(settings) > 0 {
		offered = settings[0].Enabled
	}
	switch {
	case !offered:
		add(SetupItem{ID: "google_node", Label: "Google on this node", Status: "needs_setup", Detail: "The node has no Google OAuth client, so mail and calendar cannot be connected.", Fix: "An administrator adds it under Admin → Connections → Google."})
	case s.Google != nil && s.Google.Connected(ctx, owner.String()):
		add(SetupItem{ID: "google", Label: "Your Gmail and Calendar", Status: "ready", Detail: "Connected: triage, the morning brief and background research use them."})
	default:
		add(SetupItem{ID: "google", Label: "Your Gmail and Calendar", Status: "needs_setup", Detail: "Not connected: there is no brief or triage without them.", Fix: "Connections → Google → Connect."})
	}

	// Notifications on this device.
	switch notifications {
	case "granted":
		add(SetupItem{ID: "notifications", Label: "Notifications", Status: "ready", Detail: "Approvals, briefs and finished tasks reach this device."})
	case "denied":
		add(SetupItem{ID: "notifications", Label: "Notifications", Status: "needs_setup", Detail: "Turned off on this device: you will miss approvals until you open the app.", Fix: "Allow notifications for Aseman in the device's settings."})
	default:
		add(SetupItem{ID: "notifications", Label: "Notifications", Status: "not_checked", Detail: "This device has not said whether it may notify you."})
	}

	// The person's own choices.
	p := s.person(ctx, owner, "")
	if p.Research {
		add(SetupItem{ID: "research", Label: "Background research", Status: "ready", Detail: "Every " + itoa(p.IntervalHours) + " hours, read-only.", Optional: true})
	} else {
		add(SetupItem{ID: "research", Label: "Background research", Status: "needs_setup", Detail: "Off: nothing is suggested while you are away.", Fix: "Settings → Proactive.", Optional: true})
	}
	n, _ := s.R.Count(ctx, "channel_bindings", database.Filter{Equal: map[string]any{"account_id": owner.String()}})
	if n > 0 {
		add(SetupItem{ID: "channels", Label: "Slack, Teams or SMS", Status: "ready", Detail: itoa(n) + " linked.", Optional: true})
	} else {
		add(SetupItem{ID: "channels", Label: "Slack, Teams or SMS", Status: "not_checked", Detail: "None linked: you reach your agents in the app.", Fix: "Settings → Channels.", Optional: true})
	}
	folders, _ := s.R.Count(ctx, "shared_folders", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "enabled": true}})
	if folders > 0 {
		add(SetupItem{ID: "folders", Label: "Shared folders", Status: "ready", Detail: itoa(folders) + " shared from your project computers.", Optional: true})
	} else {
		add(SetupItem{ID: "folders", Label: "Shared folders", Status: "not_checked", Detail: "None shared: each project's agents see only their own computer.", Fix: "Settings → Shared folders.", Optional: true})
	}
	return out
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
