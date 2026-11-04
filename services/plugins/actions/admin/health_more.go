package admin

import (
	"context"
	"net/http"
	"os"
	"strings"
	"time"

	llmmodels "github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// More of the deploy checklist: checks that ask the real thing (does the
// default provider accept its key? does the memory server answer?) and the
// parts that govern, connect and identify people. Each says how to fix it.

var probeClient = &http.Client{Timeout: 6 * time.Second}

// probe GETs a URL and reports whether it answered below 400.
func probe(ctx context.Context, url string, header map[string]string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := probeClient.Do(req)
	if err != nil {
		return 0, err
	}
	resp.Body.Close()
	return resp.StatusCode, nil
}

func (s *Service) moreHealth(ctx context.Context, r *repo.Repo, add func(healthCheck)) {
	// The default provider's key, asked for real.
	var providers []llmmodels.Provider
	if r.List(ctx, "llm_providers", database.Filter{}, &providers) == nil {
		for i := range providers {
			p := &providers[i]
			if !p.Enabled || !p.IsDefault || strings.TrimSpace(p.APIKey) == "" || p.BaseURL == "" {
				continue
			}
			header := map[string]string{"Authorization": "Bearer " + p.APIKey}
			if strings.Contains(p.BaseURL, "googleapis.com") {
				header = map[string]string{"X-Goog-Api-Key": p.APIKey}
			}
			code, err := probe(ctx, strings.TrimRight(p.BaseURL, "/")+"/models", header)
			switch {
			case err != nil:
				add(healthCheck{ID: "llm_key", Group: "AI", Label: "Default provider answers", Status: "fail", Detail: p.Name + " is unreachable: " + err.Error(), Fix: "Admin → Providers (base URL), the node's network"})
			case code == http.StatusUnauthorized || code == http.StatusForbidden:
				add(healthCheck{ID: "llm_key", Group: "AI", Label: "Default provider answers", Status: "fail", Detail: p.Name + " refused its key (" + itoa(int64(code)) + ").", Fix: "Admin → Providers: paste a working key"})
			case code >= 400:
				add(healthCheck{ID: "llm_key", Group: "AI", Label: "Default provider answers", Status: "warn", Detail: p.Name + " answered " + itoa(int64(code)) + " to a model list; it may still serve chat.", Fix: "Admin → Providers"})
			default:
				add(healthCheck{ID: "llm_key", Group: "AI", Label: "Default provider answers", Status: "ok", Detail: p.Name + " accepted its key"})
			}
			break
		}
	}
	// Governance
	loaded := func(ns string) bool { _, err := s.K.Resolve("service/" + ns); return err == nil }
	if !loaded("governance") {
		status := "warn"
		if os.Getenv("ASEMAN_GOVERNANCE_REQUIRED") == "1" {
			status = "fail"
		}
		add(healthCheck{ID: "governance", Group: "Governance", Label: "Action gate", Status: status, Detail: "The governance namespace is not loaded: agent actions are not decided or recorded.", Fix: "Load governance-ns"})
	} else {
		n, _ := r.Count(ctx, "governance_policies", database.Filter{Equal: map[string]any{"scope": "node"}})
		detail := "Every agent action is decided and recorded; the default policy asks before sending, paying, signing or deleting."
		if n > 0 {
			detail = "Every agent action is decided and recorded under the node's own policy."
		}
		add(healthCheck{ID: "governance", Group: "Governance", Label: "Action gate", Status: "ok", Detail: detail})
	}
	if strings.TrimSpace(os.Getenv("ASEMAN_EGRESS_IMAGE")) == "" {
		add(healthCheck{ID: "egress", Group: "Governance", Label: "Project computers' network", Status: "warn", Detail: "No egress proxy: computers connect anywhere, whatever their project's policy.", Fix: "ASEMAN_EGRESS_IMAGE=aseman/egress-proxy:v1"})
	} else {
		add(healthCheck{ID: "egress", Group: "Governance", Label: "Project computers' network", Status: "ok", Detail: "Filtered by each project's policy (" + os.Getenv("ASEMAN_EGRESS_IMAGE") + ")"})
	}
	if rt := strings.TrimSpace(os.Getenv("ASEMAN_SANDBOX_RUNTIME")); rt != "" {
		add(healthCheck{ID: "isolation", Group: "Governance", Label: "Computer isolation", Status: "ok", Detail: "Computers run under " + rt})
	}

	if loaded("hostaccess") {
		var rows []struct {
			HostEnabled bool `json:"host_enabled"`
		}
		if r.List(ctx, "hostaccess_settings", database.Filter{Limit: 1}, &rows) == nil && len(rows) > 0 && rows[0].HostEnabled {
			add(healthCheck{ID: "host_access", Group: "Governance", Label: "People's own computers", Status: "warn", Detail: "On: agents can reach folders people share from their own machines through the desktop app.", Fix: "Admin → Governance → Host access"})
		} else {
			add(healthCheck{ID: "host_access", Group: "Governance", Label: "People's own computers", Status: "ok", Detail: "Off: agents reach only project computers; people share folders from those."})
		}
	}

	// Connections
	enabledRow := func(model string, eq map[string]any) bool {
		n, err := r.Count(ctx, model, database.Filter{Equal: eq})
		return err == nil && n > 0
	}
	if loaded("google") {
		if enabledRow("google_settings", map[string]any{"enabled": true}) {
			people, _ := r.Count(ctx, "google_connections", database.Filter{Equal: map[string]any{"status": "connected"}})
			add(healthCheck{ID: "google_mail", Group: "Connections", Label: "Gmail and Calendar", Status: "ok", Detail: itoa(people) + " people connected their Google account"})
		} else {
			add(healthCheck{ID: "google_mail", Group: "Connections", Label: "Gmail and Calendar", Status: "warn", Detail: "No OAuth client: the Google app is not in the Apps catalog, so there is no morning brief or triage.", Fix: "Admin → Catalog → Connector apps"})
		}
	}
	if loaded("channels") {
		var names []string
		for _, p := range []string{"slack", "teams", "twilio"} {
			if enabledRow("channel_settings", map[string]any{"provider": p, "enabled": true}) {
				names = append(names, p)
			}
		}
		if len(names) == 0 {
			add(healthCheck{ID: "channels", Group: "Connections", Label: "Slack, Teams, SMS", Status: "warn", Detail: "None set up: people reach agents only in the app.", Fix: "Admin → Channels"})
		} else {
			add(healthCheck{ID: "channels", Group: "Connections", Label: "Slack, Teams, SMS", Status: "ok", Detail: strings.Join(names, ", ")})
		}
	}
	if envSet("ASEMAN_APNS_KEY_ID") || envSet("ASEMAN_APNS_KEY") {
		add(healthCheck{ID: "push", Group: "Connections", Label: "Push notifications", Status: "ok", Detail: "APNs configured"})
	} else {
		add(healthCheck{ID: "push", Group: "Connections", Label: "Push notifications", Status: "warn", Detail: "No APNs key: approvals and briefs reach phones only through the in-app inbox.", Fix: "ASEMAN_APNS_* in .env"})
	}

	// Enterprise
	if loaded("enterprise") {
		if enabledRow("sso_providers", map[string]any{"enabled": true}) {
			add(healthCheck{ID: "sso", Group: "Enterprise", Label: "Single sign-on", Status: "ok", Detail: "At least one provider is on"})
		} else {
			add(healthCheck{ID: "sso", Group: "Enterprise", Label: "Single sign-on", Status: "warn", Detail: "No provider: people sign in with email or Google.", Fix: "Admin → Enterprise → Single sign-on"})
		}
	}
	add(healthCheck{ID: "telemetry", Group: "Core", Label: "Telemetry", Status: "ok", Detail: "The node sends nothing to Aseman or anyone else; see docs/telemetry.md."})
}
