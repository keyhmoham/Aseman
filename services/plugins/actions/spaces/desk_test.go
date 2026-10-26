package spaces

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
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

func TestDeskAgUiOpen(t *testing.T) {
	d := Desktop{}
	now := time.Now()
	id, err := d.Apply(DeskOp{
		Op: "open", Kind: DeskAgUi, Title: "Revenue",
		Args: map[string]any{"surface": map[string]any{
			"layout": "desk",
			"root":   map[string]any{"c": "Stat", "p": map[string]any{"label": "Rev", "value": "1"}},
		}},
	}, "agent", now)
	if err != nil || id == "" {
		t.Fatal(err, id)
	}
	w := d.Windows[0]
	if w.Kind != DeskAgUi || w.Frontend != DeskAgUiFrontend || w.Tool != DeskAgUiTool {
		t.Fatalf("%+v", w)
	}
	if w.W < 500 {
		t.Fatalf("expected wider default for AG-UI viz, got %.0f", w.W)
	}
	if _, err := d.Apply(DeskOp{Op: "open", Kind: DeskAgUi, Title: "Bad", Args: map[string]any{}}, "agent", now); err == nil {
		t.Fatal("expected missing surface error")
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
