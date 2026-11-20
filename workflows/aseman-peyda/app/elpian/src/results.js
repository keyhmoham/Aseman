/* The results page: what was understood, then every service's answer side by side. */

function resultsHeader(s, app) {
  return { type: "Column", props: { style: { padding: "8 12 4 12", gap: "4", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "8", alignItems: "center" } }, children: [
      { type: "IconButton", key: "home", props: { icon: "arrow_back", tooltip: "Back to search" },
        events: { tap: app.handler("res_home", function () { app.set({ mode: "home", results: null }); }) } },
      { type: "Expanded", children: [searchField(s, app)] },
    ] },
    { type: "Row", props: { style: { padding: "0 8", alignItems: "center", gap: "8" } }, children: [
      agenticSwitch(s, app),
      { type: "Expanded", children: [T(s.results ? s.results.total + " results · " + s.results.services.filter(function (x) { return x.status === "ok"; }).length + " services answered" : (s.searching ? "Searching…" : ""),
        "labelMedium", { color: "muted", textAlign: "right" })] },
    ] },
  ] };
}

function hitCard(h, source) {
  return { type: "Card", props: { variant: "filled", style: { padding: "14", gap: "6" } }, children: [
    { type: "Row", props: { style: { gap: "8", alignItems: "flex-start" } }, children: [
      { type: "Expanded", children: [{ type: "Markdown", props: { text: linkTitle(h.title, h.url), size: "default" } }] },
      h.price_toman ? { type: "Tag", props: { text: money(h.price_toman), status: "good" } } : null,
    ].filter(Boolean) },
    h.detail ? T(h.detail, "bodySmall", { color: "muted", maxLines: 3, overflow: "ellipsis" }) : null,
    source ? T(source, "labelSmall", { color: "muted" }) : null,
  ].filter(Boolean) };
}

function serviceGroup(svc) {
  return { type: "Column", key: "svc_" + svc.id, props: { style: { gap: "8" } }, children: [
    { type: "Row", props: { style: { gap: "8", alignItems: "center" } }, children: [
      { type: "Expanded", children: [T(svc.title, "titleMediumEmphasized")] },
      { type: "Tag", props: { text: svc.count + (svc.count === 1 ? " result" : " results"), status: "info" } },
    ] },
    { type: "Column", props: { style: { gap: "8" } }, children: (svc.hits || []).map(function (h, i) { return Object.assign({}, hitCard(h), { key: "hit_" + svc.id + "_" + i }); }) },
  ] };
}

function loadingBlock() {
  var bar = function (h) { return { type: "Container", props: { style: { height: String(h), borderRadius: "20", backgroundColor: Decillion.env().theme.colors.surfaceContainerHighest } } }; };
  return { type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "12", alignItems: "center" } }, children: [
      { type: "LoadingIndicator", props: { size: 40 } },
      { type: "Expanded", children: [T("Reading your query and asking the services…", "bodyMedium", { color: "muted" })] },
    ] },
    { type: "Shimmer", children: [{ type: "Column", props: { style: { gap: "10" } }, children: [bar(24), bar(72), bar(72), bar(24), bar(72)] }] },
  ] };
}

function resultsBody(s, app) {
  if (s.searching) { return loadingBlock(); }
  if (s.searchError) {
    return { type: "Callout", props: { title: "The search did not go through", text: s.searchError, severity: "critical", icon: "error" }, children: [
      { type: "Button", key: "retry", props: { text: "Try again", icon: "refresh", variant: "tonal" }, events: { tap: app.handler("retry", function () { runSearch(app.state.q); }) } },
    ] };
  }
  var r = s.results;
  if (!r) { return null; }
  var answered = r.services.filter(function (x) { return x.count > 0; });
  var silent = r.services.filter(function (x) { return x.count === 0; });
  var shown = s.filter === "all" ? answered : answered.filter(function (x) { return x.id === s.filter; });
  var tags = understood(r.frame);
  var out = [];

  out.push({ type: "Card", props: { variant: "filled", style: { padding: "14", gap: "8" } }, children: [
    T("Understood as", "labelMedium", { color: "muted" }),
    tags.length ? { type: "Wrap", props: { style: { gap: "6" } }, children: tags.map(function (t, i) { return Object.assign({}, tagNode(t), { key: "u_" + i }); }) } : T(r.frame.text, "bodyMedium"),
    (r.frame.assumptions || []).length ? T(r.frame.assumptions.join(" · "), "labelSmall", { color: "muted" }) : null,
  ].filter(Boolean) });

  if (answered.length > 1) {
    out.push({ type: "Wrap", props: { style: { gap: "8" } }, children: [{ type: "Chip", key: "f_all", props: { label: "All", variant: "filter", selected: s.filter === "all" },
      events: { change: app.handler("f_all", function () { app.set({ filter: "all" }); }) } }].concat(answered.map(function (x) {
      return { type: "Chip", key: "f_" + x.id, props: { label: x.title + " " + x.count, variant: "filter", selected: s.filter === x.id },
        events: { change: app.handler("f_" + x.id, function () { app.set({ filter: x.id }); }) } };
    })) });
  }

  if (r.gaps && r.gaps.length) {
    var need = {};
    r.gaps.forEach(function (g) { g.missing.forEach(function (m) { need[m] = true; }); });
    out.push({ type: "Callout", props: { title: "Some services need more detail", text: "Add " + Object.keys(need).join(", ") + " to search them, or turn on agentic search and Peyda will ask.", severity: "info", icon: "tune" } });
  }

  if (!answered.length) {
    out.push({ type: "EmptyState", props: { icon: "search_off", title: "Nothing found", text: "No service had a match. Try other words, or let the agent rework the query.", action: "Try agentic search", actionIcon: "auto_awesome" },
      events: { action: app.handler("empty_agentic", function () { toggleAgentic(true); }) } });
  } else {
    shown.forEach(function (svc) { out.push(serviceGroup(svc)); });
  }

  if (silent.length) {
    out.push({ type: "Expandable", props: { title: silent.length + (silent.length === 1 ? " service" : " services") + " had nothing", icon: "info", expanded: false }, children: [
      { type: "Column", props: { style: { gap: "4" } }, children: silent.map(function (x, i) {
        return { type: "ListTile", key: "silent_" + i, props: { title: x.title, subtitle: x.reason || (x.status === "empty" ? "No matches" : x.status), leading: x.status === "error" ? "cloud_off" : "remove_circle", dense: true, lines: 2 } };
      }) },
    ] });
  }
  return { type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: out };
}

function resultsView(s, app) {
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      resultsHeader(s, app),
      { type: "Expanded", children: [{ type: "ListView", children: [
        { type: "Column", props: { style: { padding: "8 16 24 16", gap: "16", alignItems: "stretch" } }, children: [resultsBody(s, app)].filter(Boolean) },
      ] }] },
    ] },
  ] };
}
