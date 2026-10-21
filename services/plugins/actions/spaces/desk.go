package spaces

// The desk of a room: tools' frontends open as floating card windows over it,
// opened, moved, resized and closed by people and by agents alike, and kept
// between turns and sessions. Each room (and the space's home) has one desk,
// stored in the space's metadata under desktop/<room>. Coordinates are
// logical pixels from the desk's top-left corner; the desk scrolls, so a
// window may lie past the visible area. Clients report the size of the desk
// they show (viewport) so agents can place windows where people see them.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"path"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
)

// Desk geometry every client follows.
const (
	// DeskMargin keeps windows off the desk's edges.
	DeskMargin = 16.0
	// DeskBottomReserve is the band at the bottom of the viewport the dock and
	// the command bar take: windows placed for people to see stay above it.
	DeskBottomReserve  = 168.0
	deskMinW, deskMinH = 240.0, 180.0
	deskMaxSize        = 4000.0
	deskMaxWindows     = 40
	deskMaxPins        = 60
)

// Window kinds: a tool's own frontend (the default), or a widget an agent
// composed (ui_compose) from the space's tools' data and frontends, whose
// A2UI surface the window holds. Composed windows share the dock entry
// DeskComposedTool.
const (
	DeskComposed     = "composed"
	DeskComposedTool = "widgets"
)

// DeskAutoFrontend is the frontend of a window that shows an interface the
// node designed for one request, for a tool without a generative frontend
// of its own or whose generative frontend is not cached (see designWindow). The design is the window's alone: kept
// with it, never cached for the tool.
const DeskAutoFrontend = "auto"

// DeskAppFrontend: the window shows the result with the tool's own app (an
// MCP App: the ui:// resource the microtool declares), run on the device.
const DeskAppFrontend = "app"

// Web page windows: a page served from the space's sandbox through a preview
// gateway (proxy_create), typically an interactive frontend an agent built
// for a tool with Aseman's web UI kit. Its Args hold {"page": the gateway
// path, "/v1/proxy/<id>/…"}; Tool is the tool it is a frontend of, or
// DeskWebTool for a page of no tool (they share that dock entry).
const (
	DeskWeb         = "web"
	DeskWebFrontend = "web"
	DeskWebTool     = "pages"
)

// File windows: a file of the space's shared workspace, shown by the
// client's own viewer (code, documents, media). Its Args hold {"path": the
// file's path under /workspace}; every file window shares the dock entry
// DeskFileTool.
const (
	DeskFile         = "file"
	DeskFileFrontend = "file"
	DeskFileTool     = "files"
)

// Computer windows: the project's computer, its desktop live and driven in
// the window (the client asks for it, password and all, when it shows one;
// the desk keeps none of it). There is one at most.
const (
	DeskComputer         = "computer"
	DeskComputerFrontend = "computer"
	DeskComputerTool     = "computer"
)

// FilePath is the workspace path a file window shows ("" for any other).
func (w *DeskWindow) FilePath() string {
	if w.Kind != DeskFile {
		return ""
	}
	p, _ := w.Args["path"].(string)
	return p
}

// checkFilePath accepts a file inside the workspace, as /workspace/… or
// relative to it (not the workspace itself, nor the browser's saved
// logins), and returns it as /workspace/….
func checkFilePath(p string) (string, error) {
	rel := p
	if p == "/workspace" || strings.HasPrefix(p, "/workspace/") {
		rel = strings.TrimPrefix(p, "/workspace")
	}
	target, err := workspacePath(rel)
	if err != nil || p == "" || target == "/workspace" || inBrowserProfile(target) {
		return "", errs.InvalidArgument("a file window shows a file of the workspace: /workspace/…")
	}
	return target, nil
}

// Page is the gateway path a web page window shows ("" for any other).
func (w *DeskWindow) Page() string {
	if w.Kind != DeskWeb {
		return ""
	}
	page, _ := w.Args["page"].(string)
	return page
}

// checkPage accepts a preview gateway path (with a path, query or fragment
// of the page inside it), nothing else: a web window never opens another
// site with a person's sign-in.
func checkPage(page string) error {
	rest, ok := strings.CutPrefix(page, "/v1/proxy/")
	if !ok || len(rest) < 33 || rest[32] != '/' || strings.Contains(page, "..") || strings.ContainsAny(page, " \\\n\r\t") {
		return errs.InvalidArgument("a web page window shows a preview gateway path: /v1/proxy/<id>/…")
	}
	for _, c := range rest[:32] {
		if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return errs.InvalidArgument("a web page window shows a preview gateway path: /v1/proxy/<id>/…")
		}
	}
	return nil
}

// DeskDesigning is the status of a designed window whose design is under way.
const DeskDesigning = "designing"

// Compact widget shapes and sizes: on a phone the desk is a board of compact
// widgets (a summary of each window's data; tapped, the full frontend opens in
// a bottom sheet), arranged in Order on a grid of square cells.
var (
	DeskCompactShapes = []string{"card", "squircle", "pill", "circle", "leaf"}
	DeskCompactSizes  = []string{"small", "medium", "large"} // 1×1, 2×1, 2×2 cells
)

// DeskCompact is how a window sits on the phone board. Empty fields take
// the frontend's own hint, else a medium card.
type DeskCompact struct {
	Order int    `json:"order"`
	Shape string `json:"shape,omitempty"`
	Size  string `json:"size,omitempty"`
}

func oneOf(v string, allowed []string) bool {
	for _, a := range allowed {
		if v == a {
			return true
		}
	}
	return false
}

// checkCompact rejects shapes and sizes clients do not draw.
func checkCompact(c *DeskCompact) error {
	if c == nil {
		return nil
	}
	if c.Shape != "" && !oneOf(c.Shape, DeskCompactShapes) {
		return errs.InvalidArgument("compact shape is one of " + strings.Join(DeskCompactShapes, ", "))
	}
	if c.Size != "" && !oneOf(c.Size, DeskCompactSizes) {
		return errs.InvalidArgument("compact size is one of " + strings.Join(DeskCompactSizes, ", "))
	}
	return nil
}

// DeskWindow is a tool's frontend open on the desk, optionally on one result
// (the microtool called and its arguments).
type DeskWindow struct {
	ID string `json:"id"`
	// Request, Template, Status: an interface designed for one request (see
	// designWindow); Status is designing, ready or failed: <why>.
	Request   string         `json:"request,omitempty"`
	Template  map[string]any `json:"template,omitempty"`
	Status    string         `json:"status,omitempty"`
	Kind      string         `json:"kind,omitempty"`
	Widget    map[string]any `json:"widget,omitempty"`
	Tool      string         `json:"tool"`
	Name      string         `json:"name"`
	Title     string         `json:"title"`
	Frontend  string         `json:"frontend,omitempty"`
	Microtool string         `json:"microtool,omitempty"`
	Args      map[string]any `json:"args,omitempty"`
	X         float64        `json:"x"`
	Y         float64        `json:"y"`
	W         float64        `json:"w"`
	H         float64        `json:"h"`
	Z         int            `json:"z"`
	// Compact: the window as a widget on the phone board.
	Compact  *DeskCompact `json:"compact,omitempty"`
	OpenedBy string       `json:"opened_by,omitempty"`
	OpenedAt string       `json:"opened_at,omitempty"`
}

// DeskPin is a card window kept as a shortcut on the pinned desk.
type DeskPin struct {
	ID string `json:"id"`
	// Request, Template, Status: an interface designed for one request (see
	// designWindow); Status is designing, ready or failed: <why>.
	Request   string         `json:"request,omitempty"`
	Template  map[string]any `json:"template,omitempty"`
	Status    string         `json:"status,omitempty"`
	Kind      string         `json:"kind,omitempty"`
	Widget    map[string]any `json:"widget,omitempty"`
	Tool      string         `json:"tool"`
	Name      string         `json:"name"`
	Title     string         `json:"title"`
	Frontend  string         `json:"frontend,omitempty"`
	Microtool string         `json:"microtool,omitempty"`
	Args      map[string]any `json:"args,omitempty"`
	W         float64        `json:"w"`
	H         float64        `json:"h"`
	// Compact: the shape and size the widget had on the phone board.
	Compact  *DeskCompact `json:"compact,omitempty"`
	PinnedAt string       `json:"pinned_at,omitempty"`
}

// DeskViewport is the size of the desk as last shown.
type DeskViewport struct {
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// Desktop is a room's desk.
type Desktop struct {
	Version  int64        `json:"version"`
	Viewport DeskViewport `json:"viewport"`
	Windows  []DeskWindow `json:"windows"`
	Pins     []DeskPin    `json:"pins"`
}

// DeskOp is one change to a desk. Rect fields are optional: an open without
// them is placed by the node where it overlaps least.
type DeskOp struct {
	Op        string         `json:"op"` // open, move, arrange, focus, close, close_tool, pin, unpin, viewport
	ID        string         `json:"id,omitempty"`
	Kind      string         `json:"kind,omitempty"`
	Widget    map[string]any `json:"widget,omitempty"`
	Request   string         `json:"request,omitempty"`
	Template  map[string]any `json:"template,omitempty"`
	Status    string         `json:"status,omitempty"`
	Tool      string         `json:"tool,omitempty"`
	Name      string         `json:"name,omitempty"`
	Title     string         `json:"title,omitempty"`
	Frontend  string         `json:"frontend,omitempty"`
	Microtool string         `json:"microtool,omitempty"`
	Args      map[string]any `json:"args,omitempty"`
	X         *float64       `json:"x,omitempty"`
	Y         *float64       `json:"y,omitempty"`
	W         *float64       `json:"w,omitempty"`
	H         *float64       `json:"h,omitempty"`
	// Compact (open, arrange): the window on the phone board. On arrange,
	// Order is the index it moves to among the board's widgets.
	Compact *DeskCompact `json:"compact,omitempty"`
}

// compactOrder lists the windows in board order (unarranged ones after, in
// the order they opened).
func (d *Desktop) compactOrder() []*DeskWindow {
	out := make([]*DeskWindow, len(d.Windows))
	for i := range d.Windows {
		out[i] = &d.Windows[i]
	}
	sort.SliceStable(out, func(i, j int) bool {
		oi, oj := math.MaxInt32, math.MaxInt32
		if out[i].Compact != nil {
			oi = out[i].Compact.Order
		}
		if out[j].Compact != nil {
			oj = out[j].Compact.Order
		}
		return oi < oj
	})
	return out
}

// renumber gives the board's widgets the orders 0…n-1 of [order].
func renumber(order []*DeskWindow) {
	for i, w := range order {
		if w.Compact == nil {
			w.Compact = &DeskCompact{}
		}
		w.Compact.Order = i
	}
}

func (d *Desktop) viewport() DeskViewport {
	v := d.Viewport
	if v.W < 320 {
		v.W = 1200
	}
	if v.H < 320 {
		v.H = 800
	}
	return v
}

// Usable is the part of the viewport windows go in to be seen at once.
func (d *Desktop) Usable() (x, y, w, h float64) {
	v := d.viewport()
	return DeskMargin, DeskMargin, v.W - 2*DeskMargin, math.Max(deskMinH, v.H-DeskMargin-DeskBottomReserve)
}

func (d *Desktop) window(id string) *DeskWindow {
	for i := range d.Windows {
		if d.Windows[i].ID == id {
			return &d.Windows[i]
		}
	}
	return nil
}

func (d *Desktop) topZ() int {
	z := 0
	for _, w := range d.Windows {
		if w.Z > z {
			z = w.Z
		}
	}
	return z
}

func clampSize(v, min float64) float64 {
	return math.Max(min, math.Min(deskMaxSize, v))
}

// place finds where a w×h window overlaps the open ones least, scanning the
// usable area top-left first.
func (d *Desktop) place(w, h float64) (float64, float64) {
	ux, uy, uw, uh := d.Usable()
	best, bx, by := math.Inf(1), ux, uy
	const step = 24.0
	for y := uy; y+h <= uy+uh+0.5 || y == uy; y += step {
		for x := ux; x+w <= ux+uw+0.5 || x == ux; x += step {
			overlap := 0.0
			for _, o := range d.Windows {
				ox := math.Max(0, math.Min(x+w, o.X+o.W)-math.Max(x, o.X))
				oy := math.Max(0, math.Min(y+h, o.Y+o.H)-math.Max(y, o.Y))
				overlap += ox * oy
			}
			if overlap < best {
				best, bx, by = overlap, x, y
			}
			if best == 0 {
				return bx, by
			}
			if x+w > ux+uw {
				break
			}
		}
		if y+h > uy+uh {
			break
		}
	}
	return bx, by
}

func newDeskID() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Apply performs one op. It returns the id of the window an open produced
// (or focused, when the same result is already open).
func (d *Desktop) Apply(op DeskOp, actor string, now time.Time) (string, error) {
	switch op.Op {
	case "open":
		if op.Kind == DeskComposed {
			if len(op.Widget) == 0 {
				return "", errs.InvalidArgument("a composed window needs its widget")
			}
			op.Tool, op.Name, op.Frontend, op.Microtool, op.Args = DeskComposedTool, "Widgets", "generative", "", nil
		} else if op.Kind == DeskWeb {
			page, _ := op.Args["page"].(string)
			if err := checkPage(page); err != nil {
				return "", err
			}
			if op.Tool == "" || op.Tool == DeskWebTool {
				op.Tool, op.Name = DeskWebTool, "Web pages"
			}
			op.Frontend, op.Microtool, op.Args = DeskWebFrontend, "", map[string]any{"page": page}
		} else if op.Kind == DeskFile {
			raw, _ := op.Args["path"].(string)
			target, err := checkFilePath(raw)
			if err != nil {
				return "", err
			}
			if op.Title == "" {
				op.Title = path.Base(target)
			}
			op.Tool, op.Name, op.Frontend, op.Microtool, op.Args = DeskFileTool, "Files", DeskFileFrontend, "", map[string]any{"path": target}
		} else if op.Kind == DeskComputer {
			if op.Title == "" {
				op.Title = "Computer"
			}
			op.Tool, op.Name, op.Frontend, op.Microtool, op.Args = DeskComputerTool, "Computer", DeskComputerFrontend, "", nil
		} else if op.Tool == "" {
			return "", errs.InvalidArgument("open needs a tool")
		}
		// The same result twice is one window, brought to the front (for a
		// designed one, only for the same request); a widget composed again
		// under its title is refreshed in place.
		for i := range d.Windows {
			w := &d.Windows[i]
			same := w.Kind == op.Kind && w.Tool == op.Tool && w.Microtool == op.Microtool && sameArgs(w.Args, op.Args) &&
				(op.Frontend != DeskAutoFrontend || strings.EqualFold(strings.TrimSpace(w.Request), strings.TrimSpace(op.Request)))
			if op.Kind == DeskComposed {
				same = w.Kind == DeskComposed && strings.EqualFold(w.Title, op.Title)
			}
			if same {
				if op.Kind == DeskComposed {
					w.Widget = op.Widget
				}
				if op.Compact != nil && checkCompact(op.Compact) == nil {
					if w.Compact == nil {
						w.Compact = &DeskCompact{Order: len(d.Windows)}
					}
					if op.Compact.Shape != "" {
						w.Compact.Shape = op.Compact.Shape
					}
					if op.Compact.Size != "" {
						w.Compact.Size = op.Compact.Size
					}
				}
				w.Z = d.topZ() + 1
				move(w, op)
				return w.ID, nil
			}
		}
		if len(d.Windows) >= deskMaxWindows {
			return "", errs.InvalidArgument(fmt.Sprintf("the desk holds %d windows at most; close some first", deskMaxWindows))
		}
		_, _, uw, uh := d.Usable()
		w := DeskWindow{
			ID: newDeskID(), Kind: op.Kind, Widget: op.Widget, Request: op.Request, Template: op.Template, Status: op.Status, Tool: op.Tool, Name: op.Name, Title: op.Title, Frontend: op.Frontend,
			Microtool: op.Microtool, Args: op.Args,
			W: math.Min(460, uw), H: math.Min(560, uh),
			OpenedBy: actor, OpenedAt: now.UTC().Format(time.RFC3339),
		}
		if w.Title == "" {
			w.Title = w.Name
		}
		if op.W != nil {
			w.W = *op.W
		}
		if op.H != nil {
			w.H = *op.H
		}
		w.W, w.H = clampSize(w.W, deskMinW), clampSize(w.H, deskMinH)
		w.X, w.Y = d.place(w.W, w.H)
		move(&w, DeskOp{X: op.X, Y: op.Y})
		w.Z = d.topZ() + 1
		if err := checkCompact(op.Compact); err != nil {
			return "", err
		}
		// New widgets join the end of the phone board.
		w.Compact = &DeskCompact{Order: len(d.Windows)}
		if op.Compact != nil {
			w.Compact.Shape, w.Compact.Size = op.Compact.Shape, op.Compact.Size
		}
		d.Windows = append(d.Windows, w)
		renumber(d.compactOrder())
		return w.ID, nil
	case "move":
		w := d.window(op.ID)
		if w == nil {
			return "", errs.NotFound("window " + op.ID)
		}
		move(w, op)
		return w.ID, nil
	case "arrange":
		w := d.window(op.ID)
		if w == nil {
			return "", errs.NotFound("window " + op.ID)
		}
		if op.Compact == nil {
			return "", errs.InvalidArgument("arrange needs compact: {order?, shape?, size?}")
		}
		if err := checkCompact(op.Compact); err != nil {
			return "", err
		}
		order := d.compactOrder()
		if w.Compact == nil {
			w.Compact = &DeskCompact{Order: len(order)}
		}
		if op.Compact.Shape != "" {
			w.Compact.Shape = op.Compact.Shape
		}
		if op.Compact.Size != "" {
			w.Compact.Size = op.Compact.Size
		}
		// Move it to index Order among the others.
		var rest []*DeskWindow
		for _, o := range order {
			if o != w {
				rest = append(rest, o)
			}
		}
		at := op.Compact.Order
		if at < 0 {
			at = 0
		}
		if at > len(rest) {
			at = len(rest)
		}
		next := append(append(append([]*DeskWindow{}, rest[:at]...), w), rest[at:]...)
		renumber(next)
		return w.ID, nil
	case "focus":
		w := d.window(op.ID)
		if w == nil {
			return "", errs.NotFound("window " + op.ID)
		}
		w.Z = d.topZ() + 1
		return w.ID, nil
	case "close":
		n := len(d.Windows)
		d.Windows = filterWindows(d.Windows, func(w DeskWindow) bool { return w.ID != op.ID })
		if len(d.Windows) == n {
			return "", errs.NotFound("window " + op.ID)
		}
		renumber(d.compactOrder())
		return op.ID, nil
	case "close_tool":
		d.Windows = filterWindows(d.Windows, func(w DeskWindow) bool { return w.Tool != op.Tool })
		renumber(d.compactOrder())
		return "", nil
	case "pin":
		w := d.window(op.ID)
		if w == nil {
			return "", errs.NotFound("window " + op.ID)
		}
		for _, p := range d.Pins {
			same := p.Kind == w.Kind && p.Tool == w.Tool && p.Microtool == w.Microtool && sameArgs(p.Args, w.Args) && p.Request == w.Request
			if w.Kind == DeskComposed {
				same = p.Kind == DeskComposed && strings.EqualFold(p.Title, w.Title)
			}
			if same {
				return p.ID, nil
			}
		}
		if len(d.Pins) >= deskMaxPins {
			return "", errs.InvalidArgument(fmt.Sprintf("%d pins at most; unpin some first", deskMaxPins))
		}
		p := DeskPin{ID: newDeskID(), Kind: w.Kind, Widget: w.Widget, Request: w.Request, Template: w.Template, Status: w.Status, Tool: w.Tool, Name: w.Name, Title: w.Title, Frontend: w.Frontend,
			Microtool: w.Microtool, Args: w.Args, W: w.W, H: w.H, PinnedAt: now.UTC().Format(time.RFC3339)}
		if w.Compact != nil && (w.Compact.Shape != "" || w.Compact.Size != "") {
			p.Compact = &DeskCompact{Shape: w.Compact.Shape, Size: w.Compact.Size}
		}
		d.Pins = append(d.Pins, p)
		return p.ID, nil
	case "unpin":
		n := len(d.Pins)
		var kept []DeskPin
		for _, p := range d.Pins {
			if p.ID != op.ID {
				kept = append(kept, p)
			}
		}
		if len(kept) == n {
			return "", errs.NotFound("pin " + op.ID)
		}
		d.Pins = kept
		return op.ID, nil
	case "designed":
		// The node's own: a design finished (Template) or failed (Status).
		w := d.window(op.ID)
		if w == nil {
			return "", errs.NotFound("window " + op.ID)
		}
		w.Template, w.Status = op.Template, op.Status
		return w.ID, nil
	case "redesign":
		w := d.window(op.ID)
		if w == nil || w.Frontend != DeskAutoFrontend {
			return "", errs.InvalidArgument("only a designed window can be designed again")
		}
		w.Template, w.Status = nil, DeskDesigning
		return w.ID, nil
	case "viewport":
		if op.W != nil && op.H != nil && *op.W >= 200 && *op.H >= 200 {
			d.Viewport = DeskViewport{W: math.Round(*op.W), H: math.Round(*op.H)}
		}
		return "", nil
	}
	return "", errs.InvalidArgument("unknown desk op " + op.Op)
}

func move(w *DeskWindow, op DeskOp) {
	if op.W != nil {
		w.W = clampSize(*op.W, deskMinW)
	}
	if op.H != nil {
		w.H = clampSize(*op.H, deskMinH)
	}
	if op.X != nil {
		w.X = math.Max(0, math.Min(deskMaxSize, *op.X))
	}
	if op.Y != nil {
		w.Y = math.Max(0, math.Min(deskMaxSize, *op.Y))
	}
	w.X, w.Y, w.W, w.H = math.Round(w.X), math.Round(w.Y), math.Round(w.W), math.Round(w.H)
}

func filterWindows(ws []DeskWindow, keep func(DeskWindow) bool) []DeskWindow {
	out := ws[:0:0]
	for _, w := range ws {
		if keep(w) {
			out = append(out, w)
		}
	}
	return out
}

func sameArgs(a, b map[string]any) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	// Through JSON, so 1 and 1.0 (a stored number and a fresh one) agree.
	var x, y any
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	_ = json.Unmarshal(ja, &x)
	_ = json.Unmarshal(jb, &y)
	return reflect.DeepEqual(x, y)
}

// Summary describes the desk for an agent's turn: its size, where windows
// go, and what is open where.
func (d *Desktop) Summary() string {
	v := d.viewport()
	ux, uy, uw, uh := d.Usable()
	var b strings.Builder
	fmt.Fprintf(&b, "The room's desk (what people see): %.0f×%.0f px, origin top-left; place windows inside x %.0f–%.0f, y %.0f–%.0f (the dock and command bar take the bottom %.0f px); the desk scrolls past that.",
		v.W, v.H, ux, ux+uw, uy, uy+uh, DeskBottomReserve)
	if len(d.Windows) == 0 {
		b.WriteString(" No windows are open.")
	} else {
		ws := append([]DeskWindow(nil), d.Windows...)
		sort.Slice(ws, func(i, j int) bool { return ws[i].Z > ws[j].Z })
		b.WriteString(" Open windows, front first:")
		for _, w := range ws {
			args := ""
			if len(w.Args) > 0 {
				raw, _ := json.Marshal(w.Args)
				args = string(raw)
			}
			what := w.Microtool + args
			if w.Kind == DeskComposed {
				what = "composed widget"
			}
			if w.Kind == DeskWeb {
				what = "web page " + w.Page()
			}
			if w.Kind == DeskFile {
				what = "file " + w.FilePath()
			}
			if w.Kind == DeskComputer {
				what = "the project's computer: its desktop, live"
			}
			if w.Frontend == DeskAutoFrontend {
				what += ", designed for: " + strings.TrimSpace(w.Request)
				if w.Status != "" && w.Status != "ready" {
					what += " [" + w.Status + "]"
				}
			}
			fmt.Fprintf(&b, "\n- %s %q (%s) at x %.0f, y %.0f, %.0f×%.0f", w.ID, w.Title, what, w.X, w.Y, w.W, w.H)
		}
	}
	if len(d.Pins) > 0 {
		fmt.Fprintf(&b, "\n%d pinned shortcut(s).", len(d.Pins))
	}
	return b.String()
}

// --- storage ------------------------------------------------------------------

// deskKey names a room's desk ("home" for the space's own).
func deskKey(roomID identity.ID) string {
	if roomID.IsZero() {
		return "home"
	}
	return roomID.String()
}

type deskStore struct {
	mu sync.Mutex
	// mem holds desks when the node has no metadata service (tests, minimal
	// nodes).
	mem map[string]Desktop
}

func (s *Service) loadDesktop(ctx context.Context, spaceID identity.ID, room string) (Desktop, error) {
	if s.M == nil {
		return s.desks.mem[spaceID.String()+"/"+room], nil
	}
	rec, err := s.M.Get(ctx, spaceID)
	if err != nil {
		return Desktop{}, nil // no metadata yet: an empty desk
	}
	var d Desktop
	if node, ok := rec.Tree["desktop"].(map[string]any); ok {
		if raw, ok := node[room]; ok {
			b, _ := json.Marshal(raw)
			if err := json.Unmarshal(b, &d); err != nil {
				return Desktop{}, nil
			}
		}
	}
	return d, nil
}

func (s *Service) saveDesktop(ctx context.Context, spaceID identity.ID, room string, d Desktop) error {
	if s.M == nil {
		if s.desks.mem == nil {
			s.desks.mem = map[string]Desktop{}
		}
		s.desks.mem[spaceID.String()+"/"+room] = d
		return nil
	}
	b, _ := json.Marshal(d)
	var value map[string]any
	_ = json.Unmarshal(b, &value)
	return s.M.Patch(ctx, spaceID, jsonpatch.Patch{{Op: "set", Path: "desktop/" + room, Value: value}})
}

// Desk reads a room's desk.
func (s *Service) Desk(ctx context.Context, spaceID, roomID identity.ID) (Desktop, error) {
	s.desks.mu.Lock()
	defer s.desks.mu.Unlock()
	d, err := s.loadDesktop(ctx, spaceID, deskKey(roomID))
	if d.Windows == nil {
		d.Windows = []DeskWindow{}
	}
	if d.Pins == nil {
		d.Pins = []DeskPin{}
	}
	return d, err
}

// UpdateDesk applies ops to a room's desk atomically. It returns the desk
// and, per op, the id it produced.
func (s *Service) UpdateDesk(ctx context.Context, spaceID, roomID identity.ID, actor string, ops []DeskOp) (Desktop, []string, error) {
	if len(ops) == 0 || len(ops) > 100 {
		return Desktop{}, nil, errs.InvalidArgument("1..100 desk ops")
	}
	s.desks.mu.Lock()
	defer s.desks.mu.Unlock()
	room := deskKey(roomID)
	d, err := s.loadDesktop(ctx, spaceID, room)
	if err != nil {
		return Desktop{}, nil, err
	}
	now := time.Now()
	ids := make([]string, len(ops))
	viewportOnly := true
	for i, op := range ops {
		if ids[i], err = d.Apply(op, actor, now); err != nil {
			return Desktop{}, nil, err
		}
		viewportOnly = viewportOnly && op.Op == "viewport"
	}
	if !viewportOnly {
		d.Version++
	}
	if err := s.saveDesktop(ctx, spaceID, room, d); err != nil {
		return Desktop{}, nil, err
	}
	if d.Windows == nil {
		d.Windows = []DeskWindow{}
	}
	if d.Pins == nil {
		d.Pins = []DeskPin{}
	}
	return d, ids, nil
}

func equalFoldName(a, b string) bool { return strings.EqualFold(a, b) }

// designWindow designs the interface of a window opened for a tool without a
// generative frontend: the tools namespace designs it for the window's
// request, around the result it shows, and the design is kept with the
// window (never cached for the tool). It runs after the window is on the
// desk, which shows it designing meanwhile; [payer] is billed for the model.
func (s *Service) designWindow(ctx context.Context, spaceID, roomID identity.ID, w DeskWindow, payer string) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Minute)
	defer cancel()
	room := ""
	if !roomID.IsZero() {
		room = roomID.String()
	}
	var raw string
	op := DeskOp{Op: "designed", ID: w.ID, Status: "ready"}
	err := bridge.Invoke(ctx, s.K, "tools", "GenerateWindowFrontend",
		[]any{ctx, payer, spaceID.String(), room, w.Tool, w.Request, w.Microtool, w.Args}, &raw)
	if err == nil {
		err = json.Unmarshal([]byte(raw), &op.Template)
	}
	if err != nil {
		op.Template, op.Status = nil, "failed: "+err.Error()
	}
	if _, _, err := s.UpdateDesk(ctx, spaceID, roomID, "aseman", []DeskOp{op}); err != nil && s.L != nil {
		s.L.Warn("desk window design not saved", "window", w.ID, "err", err.Error())
	}
}

// designOpened starts the designs the windows [ids] wait for.
func (s *Service) designOpened(ctx context.Context, spaceID, roomID identity.ID, d Desktop, ids []string, payer string) {
	for _, id := range ids {
		w := d.window(id)
		if w != nil && w.Frontend == DeskAutoFrontend && w.Status == DeskDesigning && len(w.Template) == 0 {
			go s.designWindow(ctx, spaceID, roomID, *w, payer)
		}
	}
}
