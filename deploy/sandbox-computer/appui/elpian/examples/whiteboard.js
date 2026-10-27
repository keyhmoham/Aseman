/*
 * A reference Elpian app with a FIXED screen (see ELPIAN.md, Screen layout):
 * a whiteboard. The board fills the window on any screen — a toolbar on top,
 * the drawing surface in the Expanded free space, a navigation bar below —
 * and nothing scrolls around it, so every stroke draws. Its second tab is an
 * ordinary scrolling page (the saved boards). Also: drawing with drag events
 * in the canvas's own coordinates, a canvas `resize` event, an adaptive
 * layout from Aseman.viewport(), and a live phone widget.
 *
 * Its server answers GET api/boards -> {boards: [{id, title, strokes, updated}]}
 * and POST api/boards {title, strokes} -> {board}.
 */

var COLORS = ["onSurface", "primary", "tertiary", "error"];

var app = App.create({
  state: { strokes: [], current: null, color: 0, width: 4, tab: 0, boards: null, saving: false, size: null },

  view: function (s, app) {
    return {
      type: "Scaffold",
      children: [
        s.tab === 0 ? board(s, app) : saved(s, app),
        { type: "NavigationBar", props: { selected: s.tab, items: [
          { icon: "draw", label: "Board" },
          { icon: "bookmarks", label: "Saved", badge: s.boards && s.boards.length ? s.boards.length : undefined },
        ] }, events: { change: app.handler("tab", function (e, app) { app.set({ tab: e.value }); }) } },
      ],
    };
  },

  init: function (app) { load(); },

  widget: {
    size: "small",
    shape: "squircle",
    refreshMs: 120000,
    refresh: function () { load(); },
    view: function (s) {
      if (!s.boards) return { type: "Shimmer", children: [{ type: "Container", props: { style: { height: "48", borderRadius: "16" } } }] };
      var last = s.boards[0];
      return { type: "Column", props: { style: { gap: "4", padding: "14" } }, children: [
        { type: "Stat", props: { label: "Saved boards", value: s.boards.length, icon: "draw", size: "compact" } },
        last ? { type: "Text", props: { text: last.title, variant: "labelMedium", color: "muted", maxLines: 1, overflow: "ellipsis" } } : null,
      ] };
    },
  },
});

// The board: a fixed screen. Toolbar and palette take their height; the
// canvas takes all the rest (Expanded), whatever the window.
function board(s, app) {
  var c = Aseman.env().theme.colors;
  var wide = Aseman.viewport().sizeClass !== "compact";
  var palette = { type: "Row", props: { style: { gap: "4", alignItems: "center" } }, children: COLORS.map(function (role, i) {
    return { type: "IconButton", key: "color-" + role, props: { icon: "circle", selectedIcon: "radio_button_checked", selected: s.color === i,
      tooltip: "Pen color " + role, style: { color: c[role] } },
      events: { tap: app.handler("color_" + role, function (e, app) { app.set({ color: i }); }) } };
  }) };
  var pen = { type: "Slider", key: "pen-width", props: { value: s.width, min: 2, max: 16, divisions: 7, label: " px" },
    events: { change: app.handler("width", function (e, app) { app.set({ width: e.value }); }) } };
  return { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
    // Header: the title and the board's actions.
    { type: "Row", props: { style: { padding: "12 16 4 16", gap: "8", alignItems: "center" } }, children: [
      { type: "Expanded", children: [{ type: "Text", props: { text: "Whiteboard", variant: "headlineSmallEmphasized", maxLines: 1, overflow: "ellipsis" } }] },
      { type: "IconButton", key: "undo", props: { icon: "undo", tooltip: "Undo", disabled: !s.strokes.length },
        events: { tap: app.handler("undo", function (e, app) { app.set({ strokes: app.state.strokes.slice(0, -1) }); }) } },
      { type: "IconButton", key: "clear", props: { icon: "delete", tooltip: "Clear the board", disabled: !s.strokes.length },
        events: { tap: app.handler("clear", function (e, app) { app.set({ strokes: [] }); }) } },
      { type: "Button", key: "save", props: { text: wide ? "Save board" : "Save", icon: "bookmark_add", variant: "tonal", loading: s.saving, disabled: !s.strokes.length },
        events: { tap: app.handler("save", save) } },
    ] },
    // Pen: color and width (side by side on wide windows, stacked on phones).
    wide
      ? { type: "Row", props: { style: { padding: "0 16", gap: "16", alignItems: "center" } }, children: [palette, { type: "Expanded", children: [pen] }] }
      : { type: "Column", props: { style: { padding: "0 16", alignItems: "stretch" } }, children: [palette, pen] },
    // The surface: fills the free space; strokes are in its own coordinates.
    { type: "Expanded", children: [
      { type: "Container", props: { style: { margin: "8 16 16 16", borderRadius: "24", backgroundColor: c.surfaceContainerLowest } }, children: [
        { type: "ClipRRect", props: { style: { borderRadius: "24" } }, children: [
          { type: "Canvas", key: "board", props: { commands: draw(s, c) },
            events: {
              dragstart: app.handler("pen_down", function (e, app) {
                app.set({ current: { color: app.state.color, width: app.state.width, points: [point(e)] } });
              }),
              drag: app.handler("pen_move", function (e, app) {
                var cur = app.state.current;
                if (!cur) return;
                cur.points.push(point(e));
                app.render();
              }),
              dragend: app.handler("pen_up", function (e, app) {
                var cur = app.state.current;
                if (!cur) return;
                app.set({ strokes: app.state.strokes.concat([cur]), current: null });
              }),
              resize: app.handler("board_size", function (e, app) { app.set({ size: { width: e.width, height: e.height } }, { silent: true }); }),
            } },
        ] },
      ] },
    ] },
  ] };
}

// The saved boards: an ordinary scrolling page.
function saved(s, app) {
  var body;
  if (!s.boards) body = { type: "Center", props: { style: { padding: "48" } }, children: [{ type: "LoadingIndicator", props: { contained: true } }] };
  else if (!s.boards.length) {
    body = { type: "EmptyState", props: { icon: "bookmarks", title: "No saved boards", text: "Boards you save show up here.", action: "Start drawing", actionIcon: "draw" },
      events: { action: app.handler("start", function (e, app) { app.set({ tab: 0 }); }) } };
  } else {
    body = { type: "ListGroup", children: s.boards.map(function (b) {
      return { type: "ListTile", props: { title: b.title, subtitle: (b.strokes || []).length + " strokes", leading: "draw", trailingText: b.updated || "" },
        events: { tap: app.handler("open_" + b.id, function (e, app) { app.set({ strokes: b.strokes || [], tab: 0 }); }) } };
    }) };
  }
  return { type: "ListView", children: [{ type: "Column", props: { style: { padding: "16", gap: "16" } }, children: [
    { type: "Text", props: { text: "Saved boards", variant: "headlineSmallEmphasized" } },
    body,
  ] }] };
}

function point(e) {
  var p = e.localPosition || { x: 0, y: 0 };
  return [Math.round(p.x), Math.round(p.y)];
}

// Canvas commands for every stroke (and the one being drawn).
function draw(s, c) {
  var out = [];
  var all = s.current ? s.strokes.concat([s.current]) : s.strokes;
  for (var i = 0; i < all.length; i++) {
    var st = all[i];
    if (!st.points.length) continue;
    out.push({ type: "beginPath" });
    out.push({ type: "setStrokeStyle", params: { color: c[COLORS[st.color]] || c.onSurface } });
    out.push({ type: "setLineWidth", params: { width: st.width } });
    out.push({ type: "setLineCap", params: { cap: "round" } });
    out.push({ type: "setLineJoin", params: { join: "round" } });
    out.push({ type: "moveTo", params: { x: st.points[0][0], y: st.points[0][1] } });
    for (var k = 1; k < st.points.length; k++) out.push({ type: "lineTo", params: { x: st.points[k][0], y: st.points[k][1] } });
    if (st.points.length === 1) out.push({ type: "lineTo", params: { x: st.points[0][0] + 0.1, y: st.points[0][1] } });
    out.push({ type: "stroke" });
  }
  return out;
}

function load() {
  Aseman.fetch("api/boards")
    .then(function (r) { app.set({ boards: (r.json && r.json.boards) || [] }); })
    .catch(function (e) { app.fail(e); });
}

function save(e, app) {
  app.set({ saving: true });
  Aseman.fetch("api/boards", { method: "POST", body: { title: "Board " + ((app.state.boards || []).length + 1), strokes: app.state.strokes } })
    .then(function () { load(); })
    .catch(function (e) { app.fail(e); })
    .finally(function () { app.set({ saving: false }); });
}
