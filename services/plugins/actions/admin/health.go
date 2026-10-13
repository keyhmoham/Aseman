package admin

import (
	"context"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	llmmodels "github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// healthCheck is one line of the deploy checklist: ok = fine, warn = works but
// something is unset, fail = the platform is broken or unsafe until fixed.
type healthCheck struct {
	ID     string `json:"id"`
	Group  string `json:"group"`
	Label  string `json:"label"`
	Status string `json:"status"`
	Detail string `json:"detail"`
	// Fix says where to change it (an env var or an admin page).
	Fix string `json:"fix,omitempty"`
}

func envSet(keys ...string) bool {
	for _, k := range keys {
		if strings.TrimSpace(os.Getenv(k)) != "" {
			return true
		}
	}
	return false
}

// health inspects the node's configuration and dependencies the way an operator
// would after a deploy. It never returns secrets, only whether they are set.
func (s *Service) health(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	r := repo.New(s.K)
	checks := []healthCheck{}
	add := func(c healthCheck) { checks = append(checks, c) }

	// Core
	if n, e := r.Count(ctx, "accounts", database.Filter{}); e != nil {
		add(healthCheck{ID: "database", Group: "Core", Label: "Database", Status: "fail", Detail: "Cannot read accounts: " + e.Error(), Fix: "TRADERA_DATABASE_DSN, postgres container"})
	} else {
		add(healthCheck{ID: "database", Group: "Core", Label: "Database", Status: "ok", Detail: "Reachable, " + itoa(n) + " accounts"})
	}
	add(adminPasswordHealth(ctx, r, s.K.Env()["admin_handle"]))
	publicURL := strings.TrimSpace(os.Getenv("TRADERA_PUBLIC_URL"))
	switch {
	case publicURL == "" || strings.Contains(publicURL, "localhost") || strings.Contains(publicURL, "127.0.0.1"):
		add(healthCheck{ID: "public_url", Group: "Core", Label: "Public URL", Status: "warn", Detail: "Points at this machine (" + orDash(publicURL) + "). Phones, webhooks and peer nodes cannot reach it.", Fix: "TRADERA_PUBLIC_URL in .env"})
	case strings.HasPrefix(publicURL, "http://"):
		add(healthCheck{ID: "public_url", Group: "Core", Label: "Public URL", Status: "warn", Detail: publicURL + " is not HTTPS.", Fix: "Serve it through Caddy with a domain"})
	default:
		add(healthCheck{ID: "public_url", Group: "Core", Label: "Public URL", Status: "ok", Detail: publicURL})
	}

	// AI
	var providers []llmmodels.Provider
	if e := r.List(ctx, "llm_providers", database.Filter{}, &providers); e != nil {
		add(healthCheck{ID: "llm", Group: "AI", Label: "Model providers", Status: "fail", Detail: "Cannot read providers: " + e.Error()})
	} else {
		enabled, ready, hasDefault, models := 0, 0, false, 0
		for i := range providers {
			p := &providers[i]
			if !p.Enabled {
				continue
			}
			enabled++
			if strings.TrimSpace(p.APIKey) != "" {
				ready++
				models += len(p.ParseModels())
				if p.IsDefault {
					hasDefault = true
				}
			}
		}
		switch {
		case ready == 0:
			add(healthCheck{ID: "llm", Group: "AI", Label: "Model providers", Status: "fail", Detail: "No enabled provider has an API key, so agents cannot run.", Fix: "Admin → Providers"})
		case models == 0:
			add(healthCheck{ID: "llm", Group: "AI", Label: "Model providers", Status: "fail", Detail: "A provider is ready but has no models.", Fix: "Admin → Models"})
		case !hasDefault:
			add(healthCheck{ID: "llm", Group: "AI", Label: "Model providers", Status: "warn", Detail: itoa(int64(ready)) + " ready, " + itoa(int64(models)) + " models, but none is the default provider.", Fix: "Admin → Providers"})
		default:
			add(healthCheck{ID: "llm", Group: "AI", Label: "Model providers", Status: "ok", Detail: itoa(int64(ready)) + " ready, " + itoa(int64(models)) + " models"})
		}
	}

	// Compute
	backend := strings.ToLower(strings.TrimSpace(os.Getenv("TRADERA_SANDBOX_BACKEND")))
	if backend == "" {
		backend = "docker"
	}
	if backend == "modal" {
		if envSet("TRADERA_MODAL_TOKEN_ID") && envSet("TRADERA_MODAL_TOKEN_SECRET") {
			add(healthCheck{ID: "sandbox", Group: "Compute", Label: "Sandbox backend", Status: "ok", Detail: "Modal, image " + orDash(os.Getenv("TRADERA_SANDBOX_IMAGE"))})
		} else {
			add(healthCheck{ID: "sandbox", Group: "Compute", Label: "Sandbox backend", Status: "fail", Detail: "Modal is selected but its token is missing.", Fix: "TRADERA_MODAL_TOKEN_ID / _SECRET in .env"})
		}
	} else {
		add(healthCheck{ID: "sandbox", Group: "Compute", Label: "Sandbox backend", Status: "ok", Detail: "Docker, image " + orDash(os.Getenv("TRADERA_SANDBOX_IMAGE"))})
	}
	if nomad := strings.TrimRight(strings.TrimSpace(os.Getenv("TRADERA_NOMAD_URL")), "/"); nomad == "" {
		add(healthCheck{ID: "nomad", Group: "Compute", Label: "Agent runtime scheduler (Nomad)", Status: "warn", Detail: "No Nomad URL configured.", Fix: "TRADERA_NOMAD_URL"})
	} else {
		client := &http.Client{Timeout: 3 * time.Second}
		resp, e := client.Get(nomad + "/v1/status/leader")
		if e != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			add(healthCheck{ID: "nomad", Group: "Compute", Label: "Agent runtime scheduler (Nomad)", Status: "fail", Detail: "Not answering at " + nomad + ". Agents cannot start.", Fix: "docker compose ps nomad"})
		} else {
			resp.Body.Close()
			add(healthCheck{ID: "nomad", Group: "Compute", Label: "Agent runtime scheduler (Nomad)", Status: "ok", Detail: "Leader elected at " + nomad})
		}
	}

	// Accounts & money
	switch {
	case envSet("TRADERA_RESEND_API_KEY"):
		add(healthCheck{ID: "email", Group: "Accounts", Label: "Email", Status: "ok", Detail: "Resend, from " + orDash(os.Getenv("TRADERA_SMTP_FROM"))})
	case envSet("TRADERA_SMTP_HOST"):
		add(healthCheck{ID: "email", Group: "Accounts", Label: "Email", Status: "ok", Detail: "SMTP " + os.Getenv("TRADERA_SMTP_HOST")})
	default:
		add(healthCheck{ID: "email", Group: "Accounts", Label: "Email", Status: "warn", Detail: "Not configured: password-reset codes are only written to the node log.", Fix: "TRADERA_RESEND_API_KEY and TRADERA_SMTP_FROM"})
	}
	if envSet("TRADERA_GOOGLE_CLIENT_ID") {
		add(healthCheck{ID: "google", Group: "Accounts", Label: "Sign in with Google", Status: "ok", Detail: "Client ID set"})
	} else {
		add(healthCheck{ID: "google", Group: "Accounts", Label: "Sign in with Google", Status: "warn", Detail: "No client ID: only email sign-in works.", Fix: "node.oauth_client_id or TRADERA_GOOGLE_CLIENT_ID"})
	}
	if envSet("TRADERA_REVENUECAT_SECRET") {
		add(healthCheck{ID: "payments", Group: "Accounts", Label: "Credit purchases (RevenueCat)", Status: "ok", Detail: "Secret key set"})
	} else {
		add(healthCheck{ID: "payments", Group: "Accounts", Label: "Credit purchases (RevenueCat)", Status: "warn", Detail: "No secret key: purchases cannot be verified, so top-ups are unavailable.", Fix: "TRADERA_REVENUECAT_SECRET in .env"})
	}
	var admins []account.Account
	if e := r.List(ctx, "accounts", database.Filter{Equal: map[string]any{"role": "admin"}}, &admins); e == nil && len(admins) == 0 {
		add(healthCheck{ID: "admins", Group: "Accounts", Label: "Administrators", Status: "warn", Detail: "No account has the admin role; only the bootstrap handle can sign in as admin."})
	}

	counts := map[string]int{"ok": 0, "warn": 0, "fail": 0}
	for _, c := range checks {
		counts[c.Status]++
	}
	return helper.JSON(map[string]any{"checks": checks, "counts": counts, "generated_at": time.Now().UTC()})
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
