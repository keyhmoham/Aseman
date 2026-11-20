/* Peyda: a search engine for the Iranian web, plain or agentic. */

function submit() {
  var q = (app.state.q || "").trim();
  if (!q) { return; }
  if (app.state.agentic) { app.set({ mode: "chat", chatError: null }); newChat(q); }
  else { runSearch(q); }
}

// The switch: on, the current query becomes a conversation; off, a results page.
function toggleAgentic(on) {
  app.set({ agentic: on });
  var q = (app.state.q || "").trim();
  if (app.state.mode === "home") { return; }
  if (on) {
    if (app.state.mode === "results" && q) { newChat(q); } else { app.set({ mode: "chat" }); }
  } else {
    var lastUser = null;
    app.state.messages.forEach(function (m) { if (m.role === "user") { lastUser = m.text; } });
    var again = lastUser || q;
    if (again) { app.set({ run: null, events: [] }); runSearch(again); } else { app.set({ mode: "home" }); }
  }
}

var app = App.create({
  state: {
    mode: "home", q: "", agentic: false, info: null,
    results: null, searching: false, searchError: null, filter: "all",
    chats: [], chat: null, messages: [], composer: "", run: null, events: [], sending: false, chatError: null, showAll: false,
  },

  view: function (s, app) {
    if (s.mode === "results") { return resultsView(s, app); }
    if (s.mode === "chat") { return chatView(s, app); }
    if (s.mode === "history") { return historyView(s, app); }
    return homeView(s, app);
  },

  init: function (app) { loadInfo(); },

  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 300000,
    refresh: function (app) { loadInfo(); },
    view: function (s) {
      var size = (Decillion.env().widget || {}).size || "medium";
      var info = s.info;
      if (!info) { return { type: "Shimmer", children: [{ type: "Container", props: { style: { height: "48", borderRadius: "16" } } }] }; }
      var ready = info.extractor && info.extractor.ready;
      return { type: "Row", props: { style: { gap: "12", padding: "14", alignItems: "center" } }, children: [
        { type: "Expanded", children: [{ type: "Stat", props: { label: "Peyda searches", value: info.services, icon: "travel_explore", size: "compact" } }] },
        size === "small" ? null : { type: "Tag", props: { text: ready ? "Reading with GLiNER2" : "Warming up", status: ready ? "good" : "warning" } },
      ].filter(Boolean) };
    },
  },
});
