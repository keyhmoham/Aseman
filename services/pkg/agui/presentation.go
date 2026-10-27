// Package agui is the Aseman AG-UI surface contract for in-chat / desk visuals
// and the placement classifier that chooses among chat cards, desk AG-UI
// windows, and on-demand App UI (appui_create).
package agui

import "strings"

// Placement is where a generated UI should appear.
type Placement string

const (
	PlacementChat Placement = "chat" // inline AG-UI surface in the message stream
	PlacementDesk Placement = "desk" // card window on the room desk
	PlacementNone Placement = "none" // prose / markdown only
)

// Medium is how the UI is authored.
const (
	MediumAgui  = "agui"  // generative AG-UI surface (chat or desk)
	MediumAppui = "appui" // fullstack App UI window (appui_create)
	MediumText  = "text"
)

// Decision is the outcome of Classify.
type Decision struct {
	Placement Placement `json:"placement"`
	Reason    string    `json:"reason"`
	Medium    string    `json:"medium"` // agui | appui | text
}

// Signals are coarse intent cues from the user request / agent context.
type Signals struct {
	// NeedsHumanInput: question / options / confirm (HITL).
	NeedsHumanInput bool
	// StructuredData: tabular / metric / chart-shaped payload to show.
	StructuredData bool
	// HighComplexity: large or multi-panel viz (many series, wide tables,
	// several coordinated views) that does not fit a chat bubble cleanly.
	HighComplexity bool
	// NeedsInteractivity: filters, drill-downs, forms beyond HITL, editors.
	NeedsInteractivity bool
	// NeedsAPIs: live microtool / backend calls while the person uses the UI.
	NeedsAPIs bool
	// UserAskedForApp: they asked for an app, dashboard product, landing page,
	// or lasting workspace.
	UserAskedForApp bool
	// ExplicitMinimal: they asked for a quick look / summary card / in-chat.
	ExplicitMinimal bool
}

// Classify picks among three product paths (no duplication):
//
//  1. Low complexity + HITL-level interactivity → chat AG-UI.
//  2. High complexity / large non-interactive data viz → desk AG-UI window
//     (same component catalog, bigger canvas).
//  3. Interactivity + complexity + APIs (or an explicit app request) →
//     appui_create DeskWeb App UI.
//
// HITL always wins over desk/app so clarifications stay in the thread.
func Classify(s Signals) Decision {
	if s.NeedsHumanInput && !s.NeedsAPIs && !s.UserAskedForApp {
		return Decision{
			Placement: PlacementChat, Medium: MediumAgui,
			Reason: "human-in-the-loop belongs in chat AG-UI",
		}
	}
	if s.ExplicitMinimal && s.StructuredData && !s.NeedsAPIs {
		return Decision{
			Placement: PlacementChat, Medium: MediumAgui,
			Reason: "explicit minimal look → chat AG-UI",
		}
	}
	// Interactive product path: complex + interactive + (APIs or app ask).
	if (s.NeedsInteractivity || s.UserAskedForApp) && (s.NeedsAPIs || s.HighComplexity || s.UserAskedForApp) && !s.ExplicitMinimal {
		return Decision{
			Placement: PlacementDesk, Medium: MediumAppui,
			Reason: "interactive complex UI with APIs / app request → appui_create",
		}
	}
	if s.NeedsInteractivity && s.NeedsAPIs && !s.ExplicitMinimal {
		return Decision{
			Placement: PlacementDesk, Medium: MediumAppui,
			Reason: "live API-backed interactive UI → appui_create",
		}
	}
	// Complex / large non-interactive data visualization → desk AG-UI.
	if s.StructuredData && s.HighComplexity && !s.NeedsInteractivity && !s.NeedsAPIs && !s.ExplicitMinimal {
		return Decision{
			Placement: PlacementDesk, Medium: MediumAgui,
			Reason: "complex non-interactive visualization → desk AG-UI window",
		}
	}
	if s.StructuredData || (s.NeedsHumanInput && s.ExplicitMinimal) {
		return Decision{
			Placement: PlacementChat, Medium: MediumAgui,
			Reason: "compact visualization or HITL → chat AG-UI",
		}
	}
	if s.UserAskedForApp {
		return Decision{
			Placement: PlacementDesk, Medium: MediumAppui,
			Reason: "user asked for an app → appui_create",
		}
	}
	return Decision{Placement: PlacementNone, Medium: MediumText, Reason: "prose is enough"}
}

// InferSignals is a lightweight keyword heuristic for tests and server guards.
func InferSignals(request string) Signals {
	r := strings.ToLower(strings.TrimSpace(request))
	s := Signals{}
	for _, w := range []string{"app", "dashboard", "landing page", "website", "workspace", "full screen", "build me a", "create an interface"} {
		if strings.Contains(r, w) {
			s.UserAskedForApp = true
			break
		}
	}
	for _, w := range []string{"which ", "pick one", "choose", "confirm", "yes or no", "option", "prefer"} {
		if strings.Contains(r, w) {
			s.NeedsHumanInput = true
			break
		}
	}
	for _, w := range []string{"chart", "table", "metric", "stats", "show me the data", "visualize", "breakdown", "compare", "report"} {
		if strings.Contains(r, w) {
			s.StructuredData = true
			break
		}
	}
	for _, w := range []string{"large", "complex", "detailed", "multi-panel", "full report", "wide table", "many series", "heatmap", "dashboard view", "on the desk"} {
		if strings.Contains(r, w) {
			s.HighComplexity = true
			break
		}
	}
	for _, w := range []string{"filter", "drill", "edit", "interactive", "crud", "wizard", "multi-step", "manage", "console", "search and"} {
		if strings.Contains(r, w) {
			s.NeedsInteractivity = true
			break
		}
	}
	for _, w := range []string{"api", "live data", "call the", "microtool", "refresh from", "wire to"} {
		if strings.Contains(r, w) {
			s.NeedsAPIs = true
			break
		}
	}
	for _, w := range []string{"quick look", "in chat", "briefly", "summary card", "inline", "small card"} {
		if strings.Contains(r, w) {
			s.ExplicitMinimal = true
			break
		}
	}
	return s
}
