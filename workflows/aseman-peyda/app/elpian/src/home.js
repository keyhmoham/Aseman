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

function homeView(s, app) {
  var n = s.info && s.info.services ? s.info.services : null;
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      { type: "Row", props: { style: { padding: "8 8 0 8", justifyContent: "flex-end" } }, children: [
        signedIn() ? { type: "IconButton", key: "history", props: { icon: "history", tooltip: "Chat history", variant: "standard" },
          events: { tap: app.handler("open_history", function () { loadChats(); app.set({ mode: "history" }); }) } } : null,
      ].filter(Boolean) },
      { type: "Expanded", children: [{ type: "Center", children: [
        { type: "Column", props: { style: { padding: "0 24", gap: "20", alignItems: "stretch", maxWidth: "640" } }, children: [
          { type: "Column", props: { style: { gap: "4", alignItems: "center" } }, children: [
            T("Peyda", "displayMediumEmphasized", { color: "primary", textAlign: "center" }),
            T("پیدا", "titleLarge", { color: "muted", textAlign: "center" }),
          ] },
          searchField(s, app),
          { type: "Row", props: { style: { gap: "12", alignItems: "center", justifyContent: "center" } }, children: [
            agenticSwitch(s, app),
            { type: "Button", key: "go", props: { text: "Search", icon: "search", size: "m", disabled: !(s.q || "").trim() },
              events: { tap: app.handler("go", function () { submit(); }) } },
          ] },
          T(s.agentic ? "An AI analyst will read the results, refine the search and talk it through with you." : "Results from " + (n ? n + " " : "") + "Iranian shops, travel, health, news and more, side by side.",
            "bodySmall", { color: "muted", textAlign: "center" }),
          { type: "Wrap", props: { style: { gap: "8", justifyContent: "center" } }, children: EXAMPLES.slice(0, 4).map(function (ex, i) {
            return { type: "Chip", key: "ex_" + i, props: { label: ex, variant: "suggestion" },
              events: { tap: app.handler("ex_" + i, function () { app.set({ q: ex }); submit(); }) } };
          }) },
        ] },
      ] }] },
      { type: "Row", props: { style: { padding: "8 16 16 16", justifyContent: "center" } }, children: [
        { type: "Expanded", children: [T("Aseman Peyda · searches Digikala, Divar, Snapp, MrBilit, Paziresh24, Google Maps and more", "labelSmall", { color: "muted", textAlign: "center", maxLines: 2, overflow: "ellipsis" })] },
      ] },
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
        rows.length ? { type: "ListView", children: [{ type: "Column", props: { style: { padding: "8 16", gap: "4" } }, children: rows }] }
          : { type: "EmptyState", props: { icon: "forum", title: "No chats yet", text: "Turn on agentic search and ask Peyda something. Your conversations are kept here.", action: "Start a chat", actionIcon: "comment" },
              events: { action: app.handler("hist_start", function () { app.set({ agentic: true }); newChat(); }) } },
      ] },
    ] },
  ] };
}
