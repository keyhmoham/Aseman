package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	market "github.com/tradera/tradera/plugins/actions/market/models"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// A sample is a public MCP server an administrator can add to the catalog in
// one go. Every one here was chosen so that listing it needs nothing from the
// administrator: no key to paste, no app to register with the provider.
//
//   - Open servers answer without any sign-in.
//   - Sign-in servers let each person connect their own account in the
//     browser. They accept clients that register themselves (OAuth dynamic
//     client registration), so there is no redirect address to submit to the
//     provider first.
//   - Client servers (marked Client) are the exception: the provider wants an
//     OAuth app created by hand. They are imported with the rest, but people
//     are not offered one until its administrator saves that app's client.
type sampleServer struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	Description string `json:"description"`
	// SignIn: each person connects their own account before using it.
	SignIn bool `json:"sign_in"`
	// Site is the provider's own website, which its icon is taken from.
	Site string `json:"-"`
	// Client: the provider does not let a client register itself. It is listed
	// but not offered to people until an administrator saves an OAuth client
	// created with the provider (Edit, on the admin Tools page).
	Client bool `json:"needs_client"`
	// Scopes to ask for when the provider's own list is more than is needed.
	Scopes string `json:"-"`
}

// sampleNeedsClient reports whether the sample at an address needs an
// administrator's OAuth client.
func sampleNeedsClient(address string) bool {
	for _, sample := range sampleServers {
		if sample.URL == address {
			return sample.Client
		}
	}
	return false
}

var sampleServers = []sampleServer{
	// Open: usable by every project the moment they are listed.
	{Name: "DeepWiki", URL: "https://mcp.deepwiki.com/mcp", Site: "deepwiki.com", Description: "Ask questions about any public GitHub repository and read its documentation."},
	{Name: "Context7", URL: "https://mcp.context7.com/mcp", Site: "context7.com", Description: "Current documentation and code examples for libraries and frameworks."},
	{Name: "GitMCP", URL: "https://gitmcp.io/docs", Site: "gitmcp.io", Description: "Search and read the documentation and code of public GitHub projects."},
	{Name: "Cloudflare Docs", URL: "https://docs.mcp.cloudflare.com/mcp", Site: "cloudflare.com", Description: "Search Cloudflare's developer documentation."},
	{Name: "Hugging Face", URL: "https://huggingface.co/mcp", Site: "huggingface.co", Description: "Search models, datasets and spaces on the Hugging Face Hub."},
	{Name: "Excalidraw", URL: "https://mcp.excalidraw.com/mcp", Site: "excalidraw.com", Description: "Create and read hand-drawn style diagrams."},
	{Name: "GoDaddy Domains", URL: "https://api.godaddy.com/v1/domains/mcp", Site: "godaddy.com", Description: "Check whether domain names are available and suggest alternatives."},
	{Name: "Microsoft Learn", URL: "https://learn.microsoft.com/api/mcp", Site: "learn.microsoft.com", Description: "Search and read Microsoft's official documentation and code samples."},
	{Name: "AWS Knowledge", URL: "https://knowledge-mcp.global.api.aws", Site: "aws.amazon.com", Description: "Search AWS documentation and check which services each region has."},
	{Name: "draw.io", URL: "https://mcp.draw.io/mcp", Site: "draw.io", Description: "Create diagrams that open in draw.io."},
	{Name: "Exa", URL: "https://mcp.exa.ai/mcp", Site: "exa.ai", Description: "Search the web and fetch pages with Exa."},

	// Sign-in: each person connects their own account.
	{Name: "Todoist", URL: "https://ai.todoist.net/mcp", Site: "todoist.com", Description: "Read and manage tasks and projects in Todoist.", SignIn: true},
	{Name: "Trello", URL: "https://mcp.trello.com/v1", Site: "trello.com", Description: "Read and update Trello boards, lists and cards.", SignIn: true},
	{Name: "Calendly", URL: "https://mcp.calendly.com/", Site: "calendly.com", Description: "Look up scheduling links, events and availability in Calendly.", SignIn: true},
	{Name: "Intercom", URL: "https://mcp.intercom.com/mcp", Site: "intercom.com", Description: "Search conversations and contacts in Intercom.", SignIn: true},
	{Name: "PostHog", URL: "https://mcp.posthog.com/mcp", Site: "posthog.com", Description: "Query product analytics, feature flags and experiments in PostHog.", SignIn: true},
	{Name: "Typeform", URL: "https://api.typeform.com/mcp", Site: "typeform.com", Description: "Create forms and read responses in Typeform.", SignIn: true},
	{Name: "Jotform", URL: "https://mcp.jotform.com", Site: "jotform.com", Description: "Create forms and read submissions in Jotform.", SignIn: true},
	{Name: "Readwise", URL: "https://mcp2.readwise.io/mcp", Site: "readwise.io", Description: "Search your highlights and saved documents in Readwise.", SignIn: true},
	{Name: "Attio", URL: "https://mcp.attio.com/mcp", Site: "attio.com", Description: "Search and update people, companies and deals in Attio.", SignIn: true},
	{Name: "Klaviyo", URL: "https://mcp.klaviyo.com/mcp", Site: "klaviyo.com", Description: "Work with campaigns, lists and metrics in Klaviyo.", SignIn: true},
	{Name: "MailerLite", URL: "https://mcp.mailerlite.com/mcp", Site: "mailerlite.com", Description: "Manage subscribers and campaigns in MailerLite.", SignIn: true},
	{Name: "Buffer", URL: "https://mcp.buffer.com/mcp", Site: "buffer.com", Description: "Draft and schedule social posts in Buffer.", SignIn: true},
	{Name: "Gamma", URL: "https://mcp.gamma.app/mcp", Site: "gamma.app", Description: "Generate presentations and documents with Gamma.", SignIn: true},
	{Name: "Craft", URL: "https://mcp.craft.do/my/mcp", Site: "craft.do", Description: "Read and write documents in Craft.", SignIn: true},
	{Name: "Fireflies", URL: "https://api.fireflies.ai/mcp", Site: "fireflies.ai", Description: "Search meeting transcripts and summaries in Fireflies.", SignIn: true},
	{Name: "Otter", URL: "https://mcp.otter.ai/mcp", Site: "otter.ai", Description: "Search meeting notes and transcripts in Otter.", SignIn: true},
	{Name: "Fathom", URL: "https://api.fathom.ai/mcp", Site: "fathom.ai", Description: "Search meeting recordings and summaries in Fathom.", SignIn: true},
	{Name: "Ahrefs", URL: "https://api.ahrefs.com/mcp/mcp", Site: "ahrefs.com", Description: "SEO data: backlinks, keywords and site metrics from Ahrefs.", SignIn: true},
	{Name: "Semrush", URL: "https://mcp.semrush.com/v2/mcp", Site: "semrush.com", Description: "SEO and market data from Semrush.", SignIn: true},
	{Name: "Hunter", URL: "https://mcp.hunter.io/mcp", Site: "hunter.io", Description: "Find and verify professional email addresses with Hunter.", SignIn: true},
	{Name: "Statsig", URL: "https://api.statsig.com/v3/mcp", Site: "statsig.com", Description: "Manage feature gates and experiments in Statsig.", SignIn: true},
	{Name: "Notion", URL: "https://mcp.notion.com/mcp", Site: "notion.so", Description: "Search, read and write pages and databases in Notion.", SignIn: true},
	{Name: "Linear", URL: "https://mcp.linear.app/mcp", Site: "linear.app", Description: "Find, create and update issues and projects in Linear.", SignIn: true},
	{Name: "Atlassian", URL: "https://mcp.atlassian.com/v1/mcp", Site: "atlassian.com", Description: "Work with Jira issues and Confluence pages.", SignIn: true},
	{Name: "Asana", URL: "https://mcp.asana.com/v2/mcp", Site: "asana.com", Description: "Read and manage tasks and projects in Asana.", SignIn: true, Client: true},
	{Name: "ClickUp", URL: "https://mcp.clickup.com/mcp", Site: "clickup.com", Description: "Read and manage tasks, lists and docs in ClickUp.", SignIn: true},
	{Name: "monday.com", URL: "https://mcp.monday.com/mcp", Site: "monday.com", Description: "Read and update boards and items in monday.com.", SignIn: true},
	{Name: "Airtable", URL: "https://mcp.airtable.com/mcp", Site: "airtable.com", Description: "Read and write records in Airtable bases.", SignIn: true},
	{Name: "Miro", URL: "https://mcp.miro.com", Site: "miro.com", Description: "Read and add to Miro boards.", SignIn: true},
	{Name: "Canva", URL: "https://mcp.canva.com/mcp", Site: "canva.com", Description: "Find, create and export designs in Canva.", SignIn: true},
	{Name: "Dropbox", URL: "https://mcp.dropbox.com/mcp", Site: "dropbox.com", Description: "Search and read files in Dropbox.", SignIn: true},
	{Name: "Granola", URL: "https://mcp.granola.ai/mcp", Site: "granola.ai", Description: "Search your meeting notes in Granola.", SignIn: true},
	{Name: "Zapier", URL: "https://mcp.zapier.com/api/mcp/mcp", Site: "zapier.com", Description: "Run the actions you set up in Zapier across thousands of apps.", SignIn: true},
	{Name: "Stripe", URL: "https://mcp.stripe.com", Site: "stripe.com", Description: "Look up and manage customers, products and payments in Stripe.", SignIn: true},
	{Name: "PayPal", URL: "https://mcp.paypal.com/mcp", Site: "paypal.com", Description: "Create invoices and look up orders and payments in PayPal.", SignIn: true},
	{Name: "Square", URL: "https://mcp.squareup.com/mcp", Site: "squareup.com", Description: "Work with payments, catalog and customers in Square.", SignIn: true},
	{Name: "Webflow", URL: "https://mcp.webflow.com/mcp", Site: "webflow.com", Description: "Manage sites, pages and CMS content in Webflow.", SignIn: true},
	{Name: "Wix", URL: "https://mcp.wix.com/mcp", Site: "wix.com", Description: "Manage sites and business data in Wix.", SignIn: true},
	{Name: "Vercel", URL: "https://mcp.vercel.com", Site: "vercel.com", Description: "Inspect projects, deployments and logs on Vercel.", SignIn: true},
	{Name: "Netlify", URL: "https://netlify-mcp.netlify.app/mcp", Site: "netlify.com", Description: "Create, deploy and manage sites on Netlify.", SignIn: true},
	{Name: "Supabase", URL: "https://mcp.supabase.com/mcp", Site: "supabase.com", Description: "Manage projects, run SQL and read logs in Supabase.", SignIn: true},
	{Name: "Neon", URL: "https://mcp.neon.tech/mcp", Site: "neon.tech", Description: "Manage Postgres databases and run SQL on Neon.", SignIn: true},
	{Name: "Sentry", URL: "https://mcp.sentry.dev/mcp", Site: "sentry.io", Description: "Look into errors, issues and performance in Sentry.", SignIn: true},
	{Name: "Apify", URL: "https://mcp.apify.com", Site: "apify.com", Description: "Extract data from websites with Apify's scrapers.", SignIn: true},
	{Name: "Tavily", URL: "https://mcp.tavily.com/mcp", Site: "tavily.com", Description: "Search the web and extract page content with Tavily.", SignIn: true},

	// Client: the provider wants an OAuth app created by hand. Listed, but
	// offered to people only once its client is saved (Edit, on the admin page).
	{Name: "GitHub", URL: "https://api.githubcopilot.com/mcp/", Site: "github.com", Description: "Work with repositories, issues, pull requests and workflows on GitHub.", SignIn: true, Client: true, Scopes: "repo read:org read:user"},
	{Name: "Slack", URL: "https://mcp.slack.com/mcp", Site: "slack.com", Description: "Search and read messages and channels in Slack.", SignIn: true, Client: true},
	{Name: "HubSpot", URL: "https://mcp.hubspot.com", Site: "hubspot.com", Description: "Look up and update contacts, companies and deals in HubSpot.", SignIn: true, Client: true},
	{Name: "Box", URL: "https://mcp.box.com", Site: "box.com", Description: "Search and read files in Box.", SignIn: true, Client: true},
}

// fetchIcon downloads a site's icon: its bytes and image type, or nothing.
func (s *Service) fetchIcon(ctx context.Context, site string) ([]byte, string) {
	// The node's client for MCP servers does not follow redirects, and the icon
	// service answers with one: each hop is followed here, through that same client.
	target := "https://www.google.com/s2/favicons?sz=128&domain=" + url.QueryEscape(site)
	var response *http.Response
	for hop := 0; ; hop++ {
		request, e := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if e != nil {
			return nil, ""
		}
		if response, e = s.Client.HTTP.Do(request); e != nil {
			return nil, ""
		}
		next := response.Header.Get("Location")
		if response.StatusCode < 300 || response.StatusCode >= 400 || next == "" || hop == 3 {
			break
		}
		response.Body.Close()
		moved, e := request.URL.Parse(next)
		if e != nil || moved.Scheme != "https" {
			return nil, ""
		}
		target = moved.String()
	}
	defer response.Body.Close()
	mime := strings.TrimSpace(strings.Split(response.Header.Get("Content-Type"), ";")[0])
	if response.StatusCode != http.StatusOK || !strings.HasPrefix(mime, "image/") {
		return nil, ""
	}
	data, e := io.ReadAll(io.LimitReader(response.Body, 512<<10))
	if e != nil || len(data) == 0 {
		return nil, ""
	}
	return data, mime
}

// sampleIcon fetches a sample's icon and stores it on this node, so the app
// shows it from here and no browser asks a third party for it. It returns the
// stored file's id, or "" and why no icon could be had: a server is listed with
// or without one.
func (s *Service) sampleIcon(ctx context.Context, owner identity.ID, sample sampleServer) (string, string) {
	if sample.Site == "" {
		return "", "no site to take an icon from"
	}
	data, mime := s.fetchIcon(ctx, sample.Site)
	if data == nil {
		return "", "the icon could not be downloaded"
	}
	var file *filedata.File
	if e := bridge.Invoke(ctx, s.K, "users", "UploadFile", []any{ctx, owner, sample.Site + "-icon", mime, int64(len(data)), io.Reader(bytes.NewReader(data)), ""}, &file); e != nil {
		return "", "the icon could not be stored: " + e.Error()
	}
	if file == nil {
		return "", "the icon could not be stored"
	}
	// An avatar is shown to everyone who can see the catalog.
	file.Public = true
	if e := s.R.Update(ctx, "files", file.ID, file); e != nil {
		return "", "the icon could not be made public: " + e.Error()
	}
	return file.ID.String(), ""
}

// descriptorOf reads a registered server's descriptor as an administrator sees it.
func (s *Service) descriptorOf(ctx context.Context, req *api.ActionRequest, botID string) map[string]any {
	body, _ := json.Marshal(map[string]any{"bot": botID})
	res, e := s.K.Actions().Dispatch(ctx, "bots", "bot_detail", &api.ActionRequest{Caller: req.Caller, Body: body})
	if e != nil || res == nil {
		return nil
	}
	var view struct {
		Descriptor map[string]any `json:"descriptor"`
		Metadata   struct {
			Descriptor map[string]any `json:"descriptor"`
		} `json:"metadata"`
	}
	if json.Unmarshal(res.Body, &view) != nil {
		return nil
	}
	if view.Metadata.Descriptor != nil {
		return view.Metadata.Descriptor
	}
	return view.Descriptor
}

// giveIcon adds a sample's icon to a server already registered, unless it has
// an avatar (the sample's, or one an administrator chose). It reports whether
// one was added, and if one should have been and was not, why.
func (s *Service) giveIcon(ctx context.Context, req *api.ActionRequest, botID string, sample sampleServer) (bool, string) {
	descriptor := s.descriptorOf(ctx, req, botID)
	// The descriptor is saved whole: without the one it has, nothing is written.
	if kind, _ := descriptor["kind"].(string); kind != "mcp" {
		return false, "the server's details could not be read"
	}
	if avatar, _ := descriptor["avatar"].(string); avatar != "" {
		return false, ""
	}
	icon, why := s.sampleIcon(ctx, req.Caller.ID, sample)
	if icon == "" {
		return false, why
	}
	descriptor["avatar"] = icon
	body, _ := json.Marshal(map[string]any{"bot": botID, "descriptor": descriptor})
	if _, e := s.K.Actions().Dispatch(ctx, "bots", "bot_edit", &api.ActionRequest{Caller: req.Caller, Body: body}); e != nil {
		return false, "the icon could not be saved: " + e.Error()
	}
	return true, ""
}

// listedURLs are the addresses of the MCP servers already in the catalog.
func (s *Service) listedURLs(ctx context.Context) map[string]string {
	out := map[string]string{}
	for botID := range s.listedBots(ctx) {
		var tool models.Tool
		if s.R.GetString(ctx, "tool_registry", botID, &tool) == nil && tool.URL != "" {
			out[tool.URL] = botID
		}
	}
	return out
}

// listedBots are the tools in the catalog (an active listing), by bot id.
func (s *Service) listedBots(ctx context.Context) map[string]bool {
	out := map[string]bool{}
	var listings []market.Listing
	if e := s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"status": string(market.StatusActive)}}, &listings); e == nil {
		for _, l := range listings {
			out[l.BotID.String()] = true
		}
	}
	return out
}

// mcpSamples lists the sample servers and which are already in the catalog.
func (s *Service) mcpSamples(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	listed := s.listedURLs(ctx)
	rows := make([]map[string]any, 0, len(sampleServers))
	for _, sample := range sampleServers {
		botID := listed[sample.URL]
		// A listed sample without an avatar can still be given its icon.
		icon := false
		if botID != "" {
			avatar, _ := s.descriptorOf(ctx, req, botID)["avatar"].(string)
			icon = avatar != ""
		}
		rows = append(rows, map[string]any{"name": sample.Name, "url": sample.URL, "description": sample.Description, "sign_in": sample.SignIn, "needs_client": sample.Client, "listed": botID != "", "icon": icon})
	}
	return helper.JSON(map[string]any{"samples": rows})
}

// mcpImportSamples adds every sample server that is not in the catalog yet, each
// with its provider's icon. An open server is only listed if it answers now; one
// that does not is reported and left out. Running it again adds only what is
// missing, including the icon of a sample listed before without one.
func (s *Service) mcpImportSamples(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	listed := s.listedURLs(ctx)
	// Samples this administrator registered before that are not listed (an
	// earlier import left them waiting for review): they are listed now,
	// instead of being registered a second time.
	unlisted := map[string]models.Tool{}
	var mine []models.Tool
	if e := s.R.List(ctx, "tool_registry", database.Filter{Equal: map[string]any{"owner": req.Caller.ID.String()}}, &mine); e == nil {
		for _, tool := range mine {
			if listed[tool.URL] == "" {
				unlisted[tool.URL] = tool
			}
		}
	}
	type outcome struct {
		Name   string `json:"name"`
		Status string `json:"status"` // added | already | failed
		Error  string `json:"error,omitempty"`
		// Icon: this run gave the server its icon. IconError: it tried and could not.
		Icon      bool   `json:"icon,omitempty"`
		IconError string `json:"icon_error,omitempty"`
	}
	results := make([]outcome, len(sampleServers))
	var wg sync.WaitGroup
	slots := make(chan struct{}, 6)
	for i, sample := range sampleServers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			one, cancel := context.WithTimeout(ctx, 40*time.Second)
			defer cancel()
			// Already in the catalog: only its icon may be missing.
			if botID := listed[sample.URL]; botID != "" {
				given, why := s.giveIcon(one, req, botID, sample)
				results[i] = outcome{Name: sample.Name, Status: "already", Icon: given, IconError: why}
				return
			}
			if tool, ok := unlisted[sample.URL]; ok {
				botID, e := identity.Parse(tool.BotID)
				if e == nil {
					var listing *market.Listing
					e = bridge.Invoke(one, s.K, "market", "Publish", []any{one, req.Caller.ID, botID, market.ItemTool, sample.Name, sample.Description, int64(0), "connected-app", ""}, &listing)
				}
				if e != nil {
					results[i] = outcome{Name: sample.Name, Status: "failed", Error: e.Error()}
					return
				}
				given, why := s.giveIcon(one, req, tool.BotID, sample)
				results[i] = outcome{Name: sample.Name, Status: "added", Icon: given, IconError: why}
				return
			}
			auth := ""
			descriptor := map[string]any{"description": sample.Description}
			icon, why := s.sampleIcon(one, req.Caller.ID, sample)
			if icon != "" {
				descriptor["avatar"] = icon
			}
			if sample.SignIn {
				auth = "user"
				descriptor["mcp_oauth"] = "auto"
			}
			if sample.Client {
				descriptor["mcp_client"] = "required"
			}
			if _, e := s.registerMCP(one, req, mcpInput{Name: sample.Name, URL: sample.URL, Auth: auth, Descriptor: descriptor, Listed: true}); e != nil {
				results[i] = outcome{Name: sample.Name, Status: "failed", Error: e.Error()}
				return
			}
			results[i] = outcome{Name: sample.Name, Status: "added", Icon: icon != "", IconError: why}
		}()
	}
	wg.Wait()
	added, icons := 0, 0
	for _, r := range results {
		if r.Status == "added" {
			added++
		}
		if r.Icon {
			icons++
		}
	}
	return helper.JSON(map[string]any{"added": added, "icons": icons, "results": results})
}
