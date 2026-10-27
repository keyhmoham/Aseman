/*
 * A reference Elpian app in Material 3 Expressive (see ELPIAN.md, Design).
 * A team task board: header with the primary action, a hero stat on the
 * accent container, KPI cards, a segmented filter, a grouped list, an
 * add-task form, an agent island, designed loading / empty / error states,
 * a navigation bar, and a live phone widget.
 *
 * Its server answers GET api/tasks -> {tasks: [{id, title, owner, due, done, priority}]}
 * and POST api/tasks {title, owner, priority} / POST api/tasks/<id>/toggle.
 */

var app = App.create({
  state: { tasks: null, filter: "open", tab: 0, draft: "", owner: "", urgent: false, busy: false },

  view: function (s, app) {
    return {
      type: "Scaffold",
      children: [
        { type: "ListView", children: [
          { type: "Column", props: { style: { padding: "16", gap: "24" } }, children: [
            header(s, app),
            s.tab === 0 ? board(s, app) : null,
            s.tab === 1 ? addForm(s, app) : null,
            s.tab === 2 ? insights(s, app) : null,
          ].filter(Boolean) },
        ] },
        { type: "NavigationBar", props: { selected: s.tab, items: [
          { icon: "checklist", label: "Tasks", badge: s.tasks ? openCount(s) || undefined : undefined },
          { icon: "add_task", label: "New" },
          { icon: "insights", label: "Insights" },
        ] }, events: { change: app.handler("tab", function (e, app) { app.set({ tab: e.value }); }) } },
      ],
    };
  },

  init: function (app) { load(); },

  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 60000,
    refresh: function () { load(); },
    view: function (s) {
      var size = (Aseman.env().widget || {}).size || "medium";
      if (!s.tasks) return { type: "Shimmer", children: [{ type: "Container", props: { style: { height: "48", borderRadius: "16" } } }] };
      var open = openCount(s);
      var due = s.tasks.filter(function (t) { return !t.done && t.due === "today"; }).length;
      return { type: "Row", props: { style: { gap: "12", padding: "14", alignItems: "center" } }, children: [
        { type: "Expanded", children: [{ type: "Stat", props: { label: "Open tasks", value: open, icon: "checklist", size: "compact" } }] },
        size === "small" ? null : { type: "Column", props: { style: { gap: "6", alignItems: "flex-end" } }, children: [
          { type: "Tag", props: { text: due + " due today", status: due ? "warning" : "good" } },
          { type: "Progress", props: { value: progress(s), showValue: false, thickness: 6 } },
        ] },
      ].filter(Boolean) };
    },
  },
});

function load() {
  Aseman.fetch("api/tasks")
    .then(function (r) { app.set({ tasks: r.json.tasks || [] }); })
    .catch(function (e) { app.fail(e); });
}

function openCount(s) { return (s.tasks || []).filter(function (t) { return !t.done; }).length; }
function progress(s) { var n = (s.tasks || []).length; return n ? (n - openCount(s)) / n : 0; }

function header(s, app) {
  return { type: "Row", props: { style: { gap: "12", alignItems: "center" } }, children: [
    { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "4" } }, children: [
      { type: "Text", props: { text: "Team tasks", variant: "headlineMediumEmphasized" } },
      { type: "Text", props: { text: s.tasks ? openCount(s) + " open · " + Math.round(progress(s) * 100) + "% done" : "Loading…", variant: "bodyMedium", color: "muted" } },
    ] }] },
    { type: "IconButton", props: { icon: "refresh", variant: "tonal", tooltip: "Refresh" }, events: { tap: app.handler("reload", load) } },
  ] };
}

function board(s, app) {
  if (!s.tasks) return skeleton();
  var shown = s.tasks.filter(function (t) { return s.filter === "all" || (s.filter === "done") === !!t.done; });
  return { type: "Column", props: { style: { gap: "16" } }, children: [
    { type: "Card", props: { tone: "primary", style: { padding: "20", gap: "12" } }, children: [
      { type: "Stat", props: { label: "Sprint progress", value: progress(s), format: "percent", icon: "rocket_launch", size: "hero" } },
      { type: "Progress", props: { value: progress(s), showValue: false, wavy: progress(s) < 1 } },
    ] },
    { type: "SegmentedButton", key: "filter", props: { selected: s.filter, segments: [
      { value: "open", label: "Open", icon: "inbox" },
      { value: "done", label: "Done", icon: "task_alt" },
      { value: "all", label: "All" },
    ] }, events: { change: app.handler("filter", function (e, app) { app.set({ filter: e.value }); }) } },
    { type: "AnimatedSwitcher", children: [shown.length ? { type: "ListGroup", key: "list_" + s.filter, children: shown.map(function (t) {
      return { type: "ListTile", key: "task_" + t.id, props: {
        title: t.title, subtitle: t.owner + " · due " + t.due, leading: t.done ? "task_alt" : (t.priority === "high" ? "priority_high" : "radio_button_unchecked"),
        trailingText: t.priority === "high" ? "Urgent" : undefined,
      }, events: { tap: app.handler("toggle_" + t.id, function () { toggle(t.id); }) } };
    }) } : empty()] },
  ] };
}

function addForm(s, app) {
  return { type: "Card", props: { variant: "filled", style: { padding: "20", gap: "16" } }, children: [
    { type: "Text", props: { text: "New task", variant: "titleLargeEmphasized" } },
    app.input("draft", "draft", { label: "What needs doing?", icon: "edit" }),
    app.input("owner", "owner", { label: "Owner", icon: "person", helper: "Who picks it up" }),
    { type: "Switch", key: "urgent", props: { value: s.urgent, label: "Urgent" },
      events: { change: app.handler("urgent", function (e, app) { app.set({ urgent: !!e.value }); }) } },
    { type: "Row", props: { style: { gap: "8", justifyContent: "flex-end" } }, children: [
      { type: "Button", props: { text: "Clear", variant: "text" }, events: { tap: app.handler("clear", function (e, app) { app.set({ draft: "", owner: "" }); }) } },
      { type: "Button", props: { text: "Add task", icon: "add", loading: s.busy, disabled: !s.draft },
        events: { tap: app.handler("add", add) } },
    ] },
  ] };
}

function insights(s, app) {
  return { type: "Column", props: { style: { gap: "16" } }, children: [
    { type: "ResponsiveGrid", props: { minColumnWidth: 160, gap: 12 }, children: [
      kpi("Open", openCount(s), "inbox"),
      kpi("Done", (s.tasks || []).length - openCount(s), "task_alt"),
      kpi("Urgent", urgent(s), "priority_high"),
    ] },
    { type: "Card", props: { variant: "filled", style: { padding: "16", gap: "12" } }, children: [
      { type: "Text", props: { text: "Where the work is", variant: "titleMediumEmphasized" } },
      { type: "SegmentedBar", props: { data: [
        { label: "Done", value: (s.tasks || []).length - openCount(s), status: "good" },
        { label: "Open", value: openCount(s) - urgent(s) },
        { label: "Urgent", value: urgent(s), status: "warning" },
      ] } },
    ] },
    { type: "Card", props: { variant: "filled", style: { padding: "16" } }, children: [
      { type: "Leaderboard", props: { title: "Most done", data: byOwner(s), max: 5, format: "integer" } },
    ] },
    OpenUI.panel(app, "advice", { agent: "assistant", title: "Where to focus", auto: false, label: "Ask for a plan",
      prompt: "Suggest what the team should focus on next given these tasks: {{tasks}}", vars: { tasks: JSON.stringify(s.tasks || []) } }),
  ] };
}

function urgent(s) { return (s.tasks || []).filter(function (t) { return !t.done && t.priority === "high"; }).length; }

function byOwner(s) {
  var done = {};
  (s.tasks || []).forEach(function (t) { done[t.owner] = (done[t.owner] || 0) + (t.done ? 1 : 0); });
  return Object.keys(done).map(function (name) { return { name: name, value: done[name] }; });
}

function kpi(label, value, icon) {
  return { type: "Card", props: { variant: "filled", style: { padding: "16" } }, children: [
    { type: "Stat", props: { label: label, value: value, icon: icon } },
  ] };
}

function skeleton() {
  var bar = function (h) { return { type: "Container", props: { style: { height: String(h), borderRadius: "16", backgroundColor: Aseman.env().theme.colors.surfaceContainerHighest } } }; };
  return { type: "Shimmer", children: [{ type: "Column", props: { style: { gap: "12" } }, children: [bar(140), bar(48), bar(64), bar(64)] }] };
}

function empty() {
  return { type: "EmptyState", key: "empty", props: { icon: "celebration", title: "Nothing here", text: "Tasks in this view show up here.", action: "Add a task", actionIcon: "add_task" },
    events: { action: app.handler("empty_add", function (e, app) { app.set({ tab: 1 }); }) } };
}

function add(e, app) {
  if (!app.state.draft) return;
  app.set({ busy: true });
  Aseman.fetch("api/tasks", { method: "POST", body: { title: app.state.draft, owner: app.state.owner || "me", priority: app.state.urgent ? "high" : "normal" } })
    .then(function () { app.set({ draft: "", owner: "", urgent: false, tab: 0, filter: "open" }); load(); })
    .catch(function (err) { app.fail(err); })
    .finally(function () { app.set({ busy: false }); });
}

function toggle(id) {
  Aseman.fetch("api/tasks/" + id + "/toggle", { method: "POST" }).then(load).catch(function (e) { app.fail(e); });
}
