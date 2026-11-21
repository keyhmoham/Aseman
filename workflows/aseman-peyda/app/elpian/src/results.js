/* The results page. Phones: one column (summary, filters, the cheapest offer,
   then the results as rows with their pictures). Desk windows: a sidebar with
   what was understood and the filters, beside a grid of result tiles. */

// One word each: the segments are drawn at equal widths, and two words wrap on a phone.
var SORTS = [
  { value: "relevance", label: "Relevance" },
  { value: "price", label: "Cheapest" },
  { value: "rating", label: "Rating" },
];

function resultsHeader(s, app) {
  var wide = !isCompact();
  var bar = { type: "Row", props: { style: { gap: "8", alignItems: "center" } }, children: [
    { type: "IconButton", key: "home", props: { icon: "arrow_back", tooltip: "Back to search" },
      events: { tap: app.handler("res_home", function () { app.set({ mode: "home", results: null }); }) } },
    wide ? { type: "InkWell", key: "res_logo", events: { tap: app.handler("res_logo", function () { app.set({ mode: "home", results: null }); }) }, children: [
      { type: "Padding", props: { style: { padding: "0 8" } }, children: [T("Peyda", "titleLargeEmphasized", { color: "primary" })] } ] } : null,
    { type: "Expanded", children: [{ type: "Container", props: { style: { maxWidth: "760" } }, children: [searchField(s, app)] }] },
    wide ? agenticSwitch(s, app) : null,
  ].filter(Boolean) };
  return { type: "Column", props: { style: { padding: wide ? "12 24 8 16" : "8 12 4 8", gap: "4", alignItems: "stretch" } }, children: [
    bar,
    wide ? null : { type: "Row", props: { style: { padding: "0 4 0 8", alignItems: "center", gap: "8" } }, children: [
      agenticSwitch(s, app),
      { type: "Expanded", children: [T(summaryLine(s), "labelMedium", { color: "muted", textAlign: "right", maxLines: 1, overflow: "ellipsis" })] },
    ] },
  ].filter(Boolean) };
}

function summaryLine(s) {
  if (s.searching) { return "Searching…"; }
  if (!s.results) { return ""; }
  var ok = s.results.services.filter(function (x) { return x.status === "ok"; }).length;
  return s.results.total + " results · " + ok + " services answered";
}

/* ---- pieces ---------------------------------------------------------- */

function understoodCard(r) {
  var tags = understood(r.frame);
  return { type: "Card", key: "understood", props: { variant: "filled", radius: 24, style: { padding: "14 16", gap: "8" } }, children: [
    { type: "Row", props: { style: { gap: "8", alignItems: "center" } }, children: [
      { type: "Icon", props: { icon: "psychology", size: 18 } },
      T("Understood as", "labelLarge"),
    ] },
    tags.length ? { type: "Wrap", props: { style: { gap: "6" } }, children: tags.map(function (t, i) { return Object.assign({}, tagNode(t), { key: "u_" + i }); }) } : T(r.frame.text, "bodyMedium"),
    (r.frame.assumptions || []).length ? T(r.frame.assumptions.join(" · "), "labelSmall", { color: "muted" }) : null,
  ].filter(Boolean) };
}

function statsStrip(r, items) {
  var ok = r.services.filter(function (x) { return x.status === "ok"; }).length;
  var low = lowestPrice(items);
  var stats = [
    { label: "Results", value: r.total, icon: "search" },
    { label: "Sites answered", value: ok + " of " + r.services.length, icon: "hub" },
    { label: "Took", value: seconds(r.ms), icon: "timer" },
    low ? { label: "Lowest price", value: compactNumber(low.hit.price_toman) + " Toman", icon: "payments" } : null,
  ].filter(Boolean);
  return { type: "ResponsiveGrid", key: "stats", props: { minColumnWidth: 150, maxColumns: 4, gap: 12 }, children: stats.map(function (st, i) {
    return { type: "Card", key: "stat_" + i, props: { variant: "filled", radius: 20, style: { padding: "12 14" } }, children: [
      { type: "Stat", props: { label: st.label, value: st.value, icon: st.icon, size: "compact" } } ] };
  }) };
}

function serviceChips(s, app, answered) {
  return { type: "Wrap", key: "filters", props: { style: { gap: "8" } }, children: [
    { type: "Chip", key: "f_all", props: { label: "All", variant: "filter", selected: s.filter === "all" },
      events: { change: app.handler("f_all", function () { app.set({ filter: "all" }); }) } },
  ].concat(answered.map(function (x) {
    return { type: "Chip", key: "f_" + x.id, props: { label: x.title + " " + x.count, variant: "filter", selected: s.filter === x.id },
      events: { change: app.handler("f_" + x.id, function () { app.set({ filter: x.id }); }) } };
  })) };
}

// The sidebar's list of sites, on desk windows.
function serviceList(s, app, answered) {
  return { type: "ListGroup", key: "svc_list", props: { title: "Sites", variant: "tonal" }, children: [
    { type: "ListTile", key: "fs_all", props: { title: "All sites", leading: "list", trailingText: String(answered.reduce(function (n, x) { return n + x.count; }, 0)), selected: s.filter === "all", dense: true },
      events: { tap: app.handler("fs_all", function () { app.set({ filter: "all" }); }) } },
  ].concat(answered.map(function (x) {
    return { type: "ListTile", key: "fs_" + x.id, props: { title: x.title, leading: iconFor(x.id, ""), trailingText: String(x.count), selected: s.filter === x.id, dense: true },
      events: { tap: app.handler("fs_" + x.id, function () { app.set({ filter: x.id }); }) } };
  })) };
}

function sortControl(s, app) {
  return { type: "SegmentedButton", key: "sort", props: { selected: s.sort, size: "s",
    segments: SORTS },
    events: { change: app.handler("sort", function (e, app) { app.set({ sort: e.value || "relevance" }); }) } };
}

function viewControl(s, app) {
  return { type: "SegmentedButton", key: "view", props: { selected: s.view, size: "s", segments: [
    { value: "grouped", label: "Grouped" },
    { value: "all", label: "All" },
  ] }, events: { change: app.handler("view", function (e, app) { app.set({ view: e.value || "grouped" }); }) } };
}

function gapsCallout(r) {
  if (!r.gaps || !r.gaps.length) { return null; }
  var need = {};
  r.gaps.forEach(function (g) { g.missing.forEach(function (m) { need[m] = true; }); });
  return { type: "Callout", key: "gaps", props: { title: "Some services need more detail", text: "Add " + Object.keys(need).join(", ") + " to search them, or turn on agentic search and Peyda will ask.", severity: "info", icon: "tune" } };
}

function silentList(silent) {
  if (!silent.length) { return null; }
  return { type: "Expandable", key: "silent", props: { title: silent.length + (silent.length === 1 ? " service" : " services") + " had nothing", icon: "info", expanded: false }, children: [
    { type: "Column", props: { style: { gap: "4" } }, children: silent.map(function (x, i) {
      return { type: "ListTile", key: "silent_" + i, props: { title: x.title, subtitle: x.reason || (x.status === "empty" ? "No matches" : x.status), leading: x.status === "error" ? "cloud_off" : "remove_circle", dense: true, lines: 2 } };
    }) },
  ] };
}

function serviceSection(svc, items, app) {
  return { type: "Column", key: "svc_" + svc.id, props: { style: { gap: "10", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "10", alignItems: "center" } }, children: [
      { type: "Icon", props: { icon: iconFor(svc.id, items[0] && items[0].domain), size: 20 } },
      { type: "Expanded", children: [T(svc.title, "titleMediumEmphasized", { maxLines: 1, overflow: "ellipsis" })] },
      { type: "Tag", props: { text: svc.count + (svc.count === 1 ? " result" : " results"), status: "info" } },
    ] },
    cardGrid(items, app, { hideSource: true }),
  ] };
}

// A skeleton shaped like the results: a summary bar, then cards (rows on phones, tiles elsewhere).
function loadingBlock() {
  var c = colors();
  var box = function (h, r, extra) { return { type: "Shimmer", children: [{ type: "Container", props: { style: Object.assign({ height: String(h), borderRadius: String(r || 16), backgroundColor: c.surfaceContainerHighest }, extra || {}) } }] }; };
  var row = function (i) {
    return { type: "Row", key: "sk_" + i, props: { style: { gap: "12", alignItems: "center" } }, children: [
      box(84, 14, { width: "84" }),
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "8", alignItems: "stretch" } }, children: [box(16, 8), box(12, 6, { width: "60%" }), box(18, 9, { width: "40%" })] }] },
    ] };
  };
  var tile = function (i) {
    return { type: "Column", key: "sk_" + i, props: { style: { gap: "10", alignItems: "stretch" } }, children: [box(160, 20), box(16, 8), box(12, 6, { width: "60%" })] };
  };
  var cards = isCompact()
    ? { type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: [row(0), row(1), row(2), row(3)] }
    : { type: "ResponsiveGrid", props: { minColumnWidth: 220, maxColumns: 4, gap: 14 }, children: [tile(0), tile(1), tile(2), tile(3)] };
  return { type: "Column", key: "loading", props: { style: { gap: "20", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "12", alignItems: "center" } }, children: [
      { type: "LoadingIndicator", props: { size: 40 } },
      { type: "Expanded", children: [T("Reading your query and asking the sites…", "bodyMedium", { color: "muted" })] },
    ] },
    box(56, 24),
    cards,
  ] };
}

/* ---- the page -------------------------------------------------------- */

function resultsMain(s, app, r, answered) {
  var all = flatHits(r);
  var shownServices = s.filter === "all" ? answered : answered.filter(function (x) { return x.id === s.filter; });
  var ids = {};
  shownServices.forEach(function (x) { ids[x.id] = true; });
  var shown = all.filter(function (x) { return ids[x.service]; });
  var out = [];
  var deal = s.filter === "all" ? lowestPrice(shown) : null;
  if (deal) { out.push(dealCard(deal, app)); }
  out.push({ type: "Wrap", key: "controls", props: { style: { gap: "8", alignItems: "center" } }, children: [viewControl(s, app), s.view === "all" ? sortControl(s, app) : null].filter(Boolean) });
  if (s.view === "all") {
    out.push(cardGrid(sortHits(shown, s.sort), app));
  } else {
    shownServices.forEach(function (svc) {
      out.push(serviceSection(svc, shown.filter(function (x) { return x.service === svc.id; }), app));
    });
  }
  return out;
}

function resultsBody(s, app) {
  if (s.searching) { return [loadingBlock()]; }
  if (s.searchError) {
    return [{ type: "Callout", key: "search_error", props: { title: "The search did not go through", text: s.searchError, severity: "critical", icon: "error" }, children: [
      { type: "Button", key: "retry", props: { text: "Try again", icon: "refresh", variant: "tonal" }, events: { tap: app.handler("retry", function () { runSearch(app.state.q); }) } },
    ] }];
  }
  var r = s.results;
  if (!r) { return []; }
  var answered = r.services.filter(function (x) { return x.count > 0; });
  var silent = r.services.filter(function (x) { return x.count === 0; });
  var nothing = !answered.length ? { type: "EmptyState", key: "nothing", props: { icon: "search_off", title: "Nothing found", text: "No service had a match. Try other words, or let the agent rework the query.", action: "Try agentic search", actionIcon: "auto_awesome" },
    events: { action: app.handler("empty_agentic", function () { toggleAgentic(true); }) } } : null;

  if (isExpanded()) {
    return [{ type: "Row", key: "two_panes", props: { style: { gap: "28", alignItems: "flex-start" } }, children: [
      { type: "SizedBox", props: { style: { width: "300" } }, children: [{ type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: [
        understoodCard(r),
        answered.length > 1 ? serviceList(s, app, answered) : null,
        gapsCallout(r),
        silentList(silent),
      ].filter(Boolean) }] },
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "20", alignItems: "stretch" } }, children: [statsStrip(r, flatHits(r))].concat(nothing ? [nothing] : resultsMain(s, app, r, answered)) }] },
    ] }];
  }
  var out = [understoodCard(r)];
  if (!isCompact()) { out.push(statsStrip(r, flatHits(r))); }
  if (answered.length > 1) { out.push(serviceChips(s, app, answered)); }
  var gaps = gapsCallout(r);
  if (gaps) { out.push(gaps); }
  out = out.concat(nothing ? [nothing] : resultsMain(s, app, r, answered));
  var quiet = silentList(silent);
  if (quiet) { out.push(quiet); }
  return out;
}

function resultsView(s, app) {
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      resultsHeader(s, app),
      { type: "Divider" },
      { type: "Expanded", children: [{ type: "ListView", children: [
        pageColumn(resultsBody(s, app), { maxWidth: 1360, padding: (isCompact() ? "12 16 32 16" : "20 24 40 24"), gap: isCompact() ? "16" : "20" }),
      ] }] },
    ] },
  ] };
}
