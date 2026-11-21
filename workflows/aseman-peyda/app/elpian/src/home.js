/* The first page: a wordmark, one search box, one switch. Nothing else. */

function searchField(s, app, autofocusHint) {
  return { type: "SearchBar", key: "q", props: { hint: autofocusHint || "Search the Iranian web", value: s.q },
    events: { input: app.handler("q_input", function (e, app) { app.set({ q: e.value || "" }); }),
              submit: app.handler("q_submit", function (e, app) { submit(); }) } };
}

function agenticSwitch(s, app) {
  return { type: "Switch", key: "agentic", props: { value: s.agentic, label: "Agentic search" },
    events: { change: app.handler("agentic", function (e, app) { toggleAgentic(!!e.value); }) } };
}

function modeCard(s, app) {
  return { type: "Card", key: "mode_card", props: { variant: "filled", radius: 24, style: { padding: "12 16" } }, children: [
    { type: "Row", props: { style: { gap: "12", alignItems: "center" } }, children: [
      { type: "Icon", props: { icon: s.agentic ? "auto_awesome" : "travel_explore", size: 24, style: { color: colors().primary } } },
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "2" } }, children: [
        T(s.agentic ? "Agentic search is on" : "Plain search", "titleSmall"),
        T(s.agentic ? "An AI analyst reads the results, refines the search and talks it through with you."
          : "Results from Iranian shops, travel, health, places, news and more, side by side.", "bodySmall", { color: "muted" }),
      ] }] },
      agenticSwitch(s, app),
    ] },
  ] };
}

function categoryGrid(app) {
  return { type: "ResponsiveGrid", key: "categories", props: { minColumnWidth: 150, maxColumns: 4, gap: 12 }, children: CATEGORIES.map(function (c) {
    return { type: "Card", key: "cat_" + c.id, props: { variant: "filled", radius: 24, style: { padding: "14", gap: "10" } },
      events: { tap: app.handler("cat_" + c.id, function () { app.set({ q: c.q }); submit(); }) }, children: [
        { type: "Container", props: { style: { width: "40", height: "40", borderRadius: "14", backgroundColor: colors().primaryContainer, alignItems: "center", justifyContent: "center" } }, children: [
          { type: "Center", children: [{ type: "Icon", props: { icon: c.icon, size: 22, style: { color: colors().onPrimaryContainer } } }] } ] },
        T(c.label, "titleSmall", { maxLines: 1, overflow: "ellipsis" }),
        T(c.q, "bodySmall", { color: "muted", maxLines: 1, overflow: "ellipsis" }),
      ] };
  }) };
}

function homeView(s, app) {
  var info = s.info || {};
  var compact = isCompact();
  var ready = info.extractor && info.extractor.ready;
  var top = { type: "Row", props: { style: { padding: "8 12 0 12", gap: "4", alignItems: "center" } }, children: [
    { type: "Expanded", children: [compact ? { type: "SizedBox" } : T("Aseman Peyda", "titleSmall", { color: "muted" })] },
    signedIn() ? { type: "IconButton", key: "history", props: { icon: "history", tooltip: "Chat history", variant: "standard" },
      events: { tap: app.handler("open_history", function () { loadChats(); app.set({ mode: "history" }); }) } } : null,
  ].filter(Boolean) };
  var hero = { type: "Column", props: { style: { gap: "6", alignItems: "center", padding: compact ? "24 0 4 0" : "56 0 8 0" } }, children: [
    T("Peyda", compact ? "displayMediumEmphasized" : "displayLargeEmphasized", { color: "primary", textAlign: "center" }),
    T("پیدا · the search engine for the Iranian web", "titleMedium", { color: "muted", textAlign: "center" }),
  ] };
  var actions = { type: "Row", props: { style: { gap: "12", alignItems: "center", justifyContent: "center" } }, children: [
    { type: "Button", key: "go", props: { text: s.agentic ? "Ask Peyda" : "Search", icon: s.agentic ? "auto_awesome" : "search", size: "m", disabled: !(s.q || "").trim() },
      events: { tap: app.handler("go", function () { submit(); }) } },
  ] };
  var examples = { type: "Column", props: { style: { gap: "10", alignItems: "stretch" } }, children: [
    T("Try", "labelLarge", { color: "muted" }),
    { type: "Wrap", props: { style: { gap: "8" } }, children: EXAMPLES.slice(0, compact ? 3 : 4).map(function (ex, i) {
      return { type: "Chip", key: "ex_" + i, props: { label: ex, variant: "suggestion", icon: "arrow_outward" },
        events: { tap: app.handler("ex_" + i, function () { app.set({ q: ex }); submit(); }) } };
    }) },
  ] };
  var browse = { type: "Column", props: { style: { gap: "12", alignItems: "stretch" } }, children: [
    T("Browse by category", "titleMediumEmphasized"),
    categoryGrid(app),
  ] };
  var foot = { type: "Wrap", props: { style: { gap: "8", justifyContent: "center" } }, children: [
    info.services ? { type: "Tag", props: { text: info.services + " sites and services", icon: "hub", variant: "outline" } } : null,
    info.extractor ? { type: "Tag", props: { text: ready ? "Reading with GLiNER2" : "Model warming up", status: ready ? "good" : "warning", icon: ready ? "check_circle" : "hourglass_top" } } : null,
  ].filter(Boolean) };
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      top,
      { type: "Expanded", children: [{ type: "ListView", children: [
        pageColumn([hero, searchField(s, app), modeCard(s, app), actions, examples, browse, foot,
          T("Aseman Peyda · searches Digikala, Divar, Snapp, MrBilit, Paziresh24, Google Maps and more", "labelSmall", { color: "muted", textAlign: "center" })],
          { maxWidth: 760, gap: compact ? "20" : "24" }),
      ] }] },
    ] },
  ] };
}

function historyView(s, app) {
  var rows = (s.chats || []).map(function (c) {
    return { type: "Row", key: "chat_row_" + c.id, props: { style: { alignItems: "center", gap: "4" } }, children: [
      { type: "Expanded", children: [{ type: "ListTile", key: "chat_" + c.id, props: { title: c.title, leading: "chat_bubble", lines: 1 },
        events: { tap: app.handler("open_" + c.id, function () { app.set({ agentic: true }); openChat(c.id); }) } }] },
      { type: "IconButton", key: "del_" + c.id, props: { icon: "delete", tooltip: "Delete chat", variant: "standard" },
        events: { tap: app.handler("del_" + c.id, function () { removeChat(c.id); }) } },
    ] };
  });
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      { type: "Row", props: { style: { padding: "8 16", gap: "8", alignItems: "center" } }, children: [
        { type: "IconButton", key: "back", props: { icon: "arrow_back", tooltip: "Back" }, events: { tap: app.handler("hist_back", function () { app.set({ mode: "home" }); }) } },
        { type: "Expanded", children: [T("Chat history", "titleLargeEmphasized")] },
        { type: "IconButton", key: "new", props: { icon: "comment", tooltip: "New chat", variant: "tonal" },
          events: { tap: app.handler("hist_new", function () { app.set({ agentic: true }); newChat(); }) } },
      ] },
      { type: "Expanded", children: [
        rows.length ? { type: "ListView", children: [pageColumn(rows, { maxWidth: 760, padding: "8 " + gutter() + " 24 " + gutter(), gap: "4" })] }
          : { type: "EmptyState", props: { icon: "forum", title: "No chats yet", text: "Turn on agentic search and ask Peyda something. Your conversations are kept here.", action: "Start a chat", actionIcon: "comment" },
              events: { action: app.handler("hist_start", function () { app.set({ agentic: true }); newChat(); }) } },
      ] },
    ] },
  ] };
}
