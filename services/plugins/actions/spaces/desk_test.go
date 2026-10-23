package spaces

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(v float64) *float64 { return &v }

func TestDeskPlacesWindowsWithoutOverlap(t *testing.T) {
	d := Desktop{Viewport: DeskViewport{W: 1600, H: 900}}
	now := time.Now()
	for i := 0; i < 3; i++ {
		if _, err := d.Apply(DeskOp{Op: "open", Tool: "t", Microtool: "m", Args: map[string]any{"i": i}}, "ann", now); err != nil {
			t.Fatal(err)
		}
	}
	_, _, uw, uh := d.Usable()
	for i, a := range d.Windows {
		if a.X < DeskMargin || a.Y < DeskMargin || a.X+a.W > DeskMargin+uw || a.Y+a.H > DeskMargin+uh {
			t.Errorf("window %d outside the usable area: %+v", i, a)
		}
		for _, b := range d.Windows[i+1:] {
			if a.X < b.X+b.W && b.X < a.X+a.W && a.Y < b.Y+b.H && b.Y < a.Y+a.H {
				t.Errorf("%s overlaps %s", a.ID, b.ID)
			}
		}
	}
	if d.Windows[2].Z <= d.Windows[1].Z {
		t.Error("a new window opens in front")
	}
}

func TestDeskOps(t *testing.T) {
	d := Desktop{}
	now := time.Now()
	a, _ := d.Apply(DeskOp{Op: "open", Tool: "wx", Microtool: "report", Args: map[string]any{"city": "NY"}, X: f(40), Y: f(50), W: f(100)}, "agent", now)
	// The same result again is the same window, brought forward and moved.
	b, _ := d.Apply(DeskOp{Op: "open", Tool: "wx", Microtool: "report", Args: map[string]any{"city": "NY"}}, "ann", now)
	if a != b || len(d.Windows) != 1 {
		t.Fatalf("duplicate result opened twice: %v", d.Windows)
	}
	w := d.Windows[0]
	if w.X != 40 || w.Y != 50 || w.W != deskMinW {
		t.Fatalf("explicit rect (clamped to the minimum width): %+v", w)
	}
	c, _ := d.Apply(DeskOp{Op: "open", Tool: "wx", Microtool: "report", Args: map[string]any{"city": "Paris"}}, "ann", now)
	d.Apply(DeskOp{Op: "open", Tool: "notes"}, "ann", now)
	if _, err := d.Apply(DeskOp{Op: "move", ID: a, X: f(300), H: f(400)}, "ann", now); err != nil || d.window(a).X != 300 || d.window(a).H != 400 {
		t.Fatal("move", err)
	}
	d.Apply(DeskOp{Op: "focus", ID: a}, "ann", now)
	if d.window(a).Z != d.topZ() {
		t.Fatal("focus brings to front")
	}
	p1, _ := d.Apply(DeskOp{Op: "pin", ID: c}, "ann", now)
	p2, _ := d.Apply(DeskOp{Op: "pin", ID: c}, "ann", now)
	if p1 != p2 || len(d.Pins) != 1 || d.Pins[0].Args["city"] != "Paris" {
		t.Fatalf("pins: %+v", d.Pins)
	}
	// Closing a tool closes all its windows in one go; pins stay.
	d.Apply(DeskOp{Op: "close_tool", Tool: "wx"}, "ann", now)
	if len(d.Windows) != 1 || d.Windows[0].Tool != "notes" || len(d.Pins) != 1 {
		t.Fatalf("close_tool: %+v", d.Windows)
	}
	if _, err := d.Apply(DeskOp{Op: "close", ID: "nope"}, "ann", now); err == nil {
		t.Fatal("closing a missing window")
	}
	if _, err := d.Apply(DeskOp{Op: "unpin", ID: p1}, "ann", now); err != nil || len(d.Pins) != 0 {
		t.Fatal("unpin", err)
	}
	if _, err := d.Apply(DeskOp{Op: "dance"}, "ann", now); err == nil {
		t.Fatal("unknown op")
	}
}

func TestDeskPersistsAndDescribesItself(t *testing.T) {
	s, ctx := messageToolHarness(t)
	sp, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000001"), "desk space", "")
	if err != nil {
		t.Fatal(err)
	}
	space, room := sp.ID, identity.ID{Node: 1, Entity: 6}
	d, _, err := s.UpdateDesk(ctx, space, room, "ann", []DeskOp{{Op: "viewport", W: f(1000), H: f(700)}})
	if err != nil || d.Version != 0 {
		t.Fatalf("a viewport report is not a change people see: %v %v", d.Version, err)
	}
	d, ids, err := s.UpdateDesk(ctx, space, room, "agent", []DeskOp{{Op: "open", Tool: "wx", Title: "Weather in NY", Microtool: "report", Args: map[string]any{"city": "NY"}}})
	if err != nil || d.Version != 1 || ids[0] == "" {
		t.Fatal(d, err)
	}
	again, _ := s.Desk(ctx, space, room)
	if len(again.Windows) != 1 || again.Viewport.W != 1000 {
		t.Fatalf("not kept: %+v", again)
	}
	other, _ := s.Desk(ctx, space, identity.ID{})
	if len(other.Windows) != 0 {
		t.Fatal("each room has its own desk")
	}
	sum := again.Summary()
	for _, want := range []string{"1000×700", ids[0], "Weather in NY", `report{"city":"NY"}`, "dock"} {
		if !strings.Contains(sum, want) {
			t.Errorf("summary lacks %q:\n%s", want, sum)
		}
	}
}

func TestComposedWidgetsOpenOnTheDeskNotInTheChat(t *testing.T) {
	s, ctx := messageToolHarness(t)
	sp, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000001"), "compose space", "")
	if err != nil {
		t.Fatal(err)
	}
	room := identity.ID{Node: 1, Entity: 9}
	compose := func(text string) string {
		out, err := s.composeUI(ctx, sp.ID, room, "aseman",
			`{"title":"Portfolio","x":30,"y":40,"components":[{"id":"root","component":"Text","text":"`+text+`"}]}`)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	first := compose("v1")
	if !strings.Contains(first, `"window"`) || !strings.Contains(first, "composed widget") {
		t.Fatalf("compose result: %s", first)
	}
	compose("v2") // the same title: the same window, refreshed
	d, _ := s.Desk(ctx, sp.ID, room)
	if len(d.Windows) != 1 {
		t.Fatalf("windows: %+v", d.Windows)
	}
	w := d.Windows[0]
	if w.Kind != DeskComposed || w.Tool != DeskComposedTool || w.X != 30 || w.Y != 40 {
		t.Fatalf("window: %+v", w)
	}
	raw, _ := json.Marshal(w.Widget)
	if !strings.Contains(string(raw), `"text":"v2"`) || strings.Contains(string(raw), `"text":"v1"`) {
		t.Fatalf("widget not refreshed: %s", raw)
	}
	// Pinned and reopened as it was.
	d, ids, err := s.UpdateDesk(ctx, sp.ID, room, "ann", []DeskOp{{Op: "pin", ID: w.ID}, {Op: "close", ID: w.ID}})
	if err != nil || len(d.Pins) != 1 || d.Pins[0].Kind != DeskComposed || ids[0] == "" {
		t.Fatalf("pin: %+v %v", d.Pins, err)
	}
	pin := d.Pins[0]
	ops := []DeskOp{{Op: "open", Kind: pin.Kind, Title: pin.Title, Widget: pin.Widget}}
	if err := s.resolveDeskOpens(ctx, sp.ID, ops); err != nil {
		t.Fatal(err)
	}
	if d, _, err = s.UpdateDesk(ctx, sp.ID, room, "ann", ops); err != nil || len(d.Windows) != 1 || d.Windows[0].Kind != DeskComposed {
		t.Fatalf("reopen: %+v %v", d.Windows, err)
	}
	// Nothing was posted to the room.
	var msgs []map[string]any
	if err := s.R.List(ctx, "messages", database.Filter{}, &msgs); err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 0 {
		t.Fatalf("composed widgets reached the chat: %v", msgs)
	}
}

func TestDesignedWindowsBelongToTheirRequest(t *testing.T) {
	d := Desktop{}
	now := time.Now()
	open := func(request string) string {
		id, err := d.Apply(DeskOp{Op: "open", Tool: "notes", Frontend: DeskAutoFrontend, Status: DeskDesigning,
			Request: request, Microtool: "search", Args: map[string]any{"q": "tax"}}, "agent", now)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	a := open("Which notes mention tax?")
	b := open("Summarize my tax notes as a timeline")
	if a == b || len(d.Windows) != 2 {
		t.Fatal("another request for the same result is another window, designed for it")
	}
	if again := open("which notes mention tax? "); again != a {
		t.Fatal("the same request again is the same window")
	}
	tpl := map[string]any{"title": "Tax notes", "components": []any{map[string]any{"id": "root", "component": "Text", "text": "x"}}}
	if _, err := d.Apply(DeskOp{Op: "designed", ID: a, Template: tpl, Status: "ready"}, "aseman", now); err != nil {
		t.Fatal(err)
	}
	if w := d.window(a); w.Status != "ready" || w.Template["title"] != "Tax notes" {
		t.Fatalf("design saved with the window: %+v", w)
	}
	if !strings.Contains(d.Summary(), "designed for: Summarize my tax notes as a timeline [designing]") {
		t.Fatalf("agents see what each window was designed for:\n%s", d.Summary())
	}
	if _, err := d.Apply(DeskOp{Op: "redesign", ID: a}, "ann", now); err != nil || d.window(a).Status != DeskDesigning || d.window(a).Template != nil {
		t.Fatal("redesign starts over", err)
	}
	// Pinned with its design, so reopening it needs no new one.
	d.Apply(DeskOp{Op: "designed", ID: b, Template: tpl, Status: "ready"}, "aseman", now)
	p, _ := d.Apply(DeskOp{Op: "pin", ID: b}, "ann", now)
	if pin := d.Pins[0]; pin.ID != p || pin.Request == "" || pin.Template == nil {
		t.Fatalf("pin: %+v", pin)
	}
}

func TestADesignThatCannotBeMadeSaysWhy(t *testing.T) {
	s, ctx := messageToolHarness(t)
	sp, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000001"), "design space", "")
	if err != nil {
		t.Fatal(err)
	}
	room := identity.ID{Node: 1, Entity: 9}
	d, ids, err := s.UpdateDesk(ctx, sp.ID, room, "agent", []DeskOp{{Op: "open", Tool: "notes", Frontend: DeskAutoFrontend,
		Status: DeskDesigning, Request: "Which notes mention tax?"}})
	if err != nil {
		t.Fatal(err)
	}
	// No tools namespace in this node: the design fails, and the window says so.
	s.designWindow(ctx, sp.ID, room, *d.window(ids[0]), "")
	d, _ = s.Desk(ctx, sp.ID, room)
	if w := d.window(ids[0]); !strings.HasPrefix(w.Status, "failed: ") || w.Template != nil {
		t.Fatalf("status: %+v", w)
	}
}

func TestThePhoneBoardKeepsItsArrangement(t *testing.T) {
	var d Desktop
	now := time.Now()
	ids := make([]string, 3)
	for i, tool := range []string{"a", "b", "c"} {
		id, err := d.Apply(DeskOp{Op: "open", Tool: tool, Name: tool}, "me", now)
		if err != nil {
			t.Fatal(err)
		}
		ids[i] = id
	}
	order := func() string {
		var out []string
		for _, w := range d.compactOrder() {
			out = append(out, w.Tool)
		}
		return strings.Join(out, "")
	}
	if got := order(); got != "abc" {
		t.Fatalf("new widgets join the end: %s", got)
	}
	if _, err := d.Apply(DeskOp{Op: "arrange", ID: ids[2], Compact: &DeskCompact{Order: 0, Shape: "circle", Size: "small"}}, "me", now); err != nil {
		t.Fatal(err)
	}
	if got := order(); got != "cab" {
		t.Fatalf("arranged to the front: %s", got)
	}
	c := d.window(ids[2]).Compact
	if c.Shape != "circle" || c.Size != "small" {
		t.Fatalf("shape and size kept: %+v", c)
	}
	if _, err := d.Apply(DeskOp{Op: "arrange", ID: ids[0], Compact: &DeskCompact{Order: 9}}, "me", now); err != nil {
		t.Fatal(err)
	}
	if got := order(); got != "cba" {
		t.Fatalf("an order past the end moves it last: %s", got)
	}
	for _, bad := range []*DeskCompact{{Shape: "star"}, {Size: "huge"}} {
		if _, err := d.Apply(DeskOp{Op: "arrange", ID: ids[0], Compact: bad}, "me", now); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
	if _, err := d.Apply(DeskOp{Op: "close", ID: ids[2]}, "me", now); err != nil {
		t.Fatal(err)
	}
	for i, w := range d.compactOrder() {
		if w.Compact.Order != i {
			t.Fatalf("orders stay 0…n-1 after a close: %s at %d", w.Tool, w.Compact.Order)
		}
	}
	// A pin keeps the widget's look; opening it again restores it.
	if _, err := d.Apply(DeskOp{Op: "pin", ID: ids[2]}, "me", now); err == nil {
		t.Fatal("pinned a closed window")
	}
	if _, err := d.Apply(DeskOp{Op: "arrange", ID: ids[1], Compact: &DeskCompact{Order: 0, Shape: "leaf"}}, "me", now); err != nil {
		t.Fatal(err)
	}
	pin, err := d.Apply(DeskOp{Op: "pin", ID: ids[1]}, "me", now)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range d.Pins {
		if p.ID == pin && (p.Compact == nil || p.Compact.Shape != "leaf") {
			t.Fatalf("the pin keeps the shape: %+v", p.Compact)
		}
	}
}

// A composed widget is checked before it opens: one that does not work
// comes back to the agent with what to fix, and nothing opens.
func TestComposedWidgetsAreCheckedBeforeOpening(t *testing.T) {
	s, ctx := messageToolHarness(t)
	sp, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000001"), "compose space", "")
	if err != nil {
		t.Fatal(err)
	}
	room := identity.ID{Node: 1, Entity: 9}
	_, err = s.composeUI(ctx, sp.ID, room, "aseman", `{"title":"Broken","components":[
		{"id":"root","component":"Column","children":["total","buy"]},
		{"id":"total","component":"Stat","label":"Total","value":{"path":"/summary/total"}},
		{"id":"buy","component":"Button","child":"buy_t","action":{"event":{"name":"buy"}}},
		{"id":"buy_t","component":"Text","text":"Buy"}]}`)
	if err == nil {
		t.Fatal("a broken widget opened")
	}
	for _, want := range []string{"nothing was opened", "/summary/total, which nothing fills", "sends the event buy"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("report lacks %q: %v", want, err)
		}
	}
	if d, _ := s.Desk(ctx, sp.ID, room); len(d.Windows) != 0 {
		t.Fatalf("windows: %+v", d.Windows)
	}
}
