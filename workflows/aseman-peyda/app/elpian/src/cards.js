/* Result cards: one hit as a picture, a title that links to the site, its
   price or rating, and where it came from. Two shapes: a row (phones: the
   picture on the side) and a tile (grids on wider windows: the picture on top).
   A hit without a picture gets a tonal panel with its category's icon, so a
   grid stays even. */

function placeholder(item, style) {
  var c = colors();
  return { type: "Container", props: { style: Object.assign({ backgroundColor: c.surfaceContainerHighest, alignItems: "center", justifyContent: "center" }, style || {}) }, children: [
    { type: "Center", children: [{ type: "Icon", props: { icon: iconFor(item.service, item.domain), size: 32, style: { color: c.onSurfaceVariant } } }] },
  ] };
}

// The hit's picture, cropped to fill; `w`/`h` in px, or a ratio for a tile.
function picture(item, opts) {
  var src = imageUrl(item.hit);
  var radius = String(opts.radius || 16);
  var box = opts.ratio
    ? function (child) { return { type: "AspectRatio", props: { aspectRatio: opts.ratio }, children: [child] }; }
    : function (child) { return { type: "SizedBox", props: { style: { width: String(opts.size), height: String(opts.size) } }, children: [child] }; };
  var inner = src
    ? { type: "Image", props: { src: src, fit: "cover", alt: item.hit.title || "Result picture", style: { width: "100%", height: "100%" } } }
    : placeholder(item, { width: "100%", height: "100%" });
  return { type: "ClipRRect", props: { style: { borderRadius: radius } }, children: [box(inner)] };
}

function priceText(h) {
  return h.price_toman ? T(money(h.price_toman), "titleMediumEmphasized", { color: "primary" }) : null;
}

function ratingTag(h) {
  var r = ratingOf(h);
  if (!r) { return null; }
  return { type: "Tag", props: { text: r.value.toFixed(1) + (r.count ? " · " + compactNumber(r.count) : ""), icon: "star", status: r.value >= 4 ? "good" : "info" } };
}

function sourceTag(item) {
  return { type: "Tag", props: { text: item.source, icon: iconFor(item.service, item.domain), variant: "outline" } };
}

// The detail line without what the card already shows (the rating).
function detailText(h) {
  return String(h.detail || "")
    .replace(/★\s*[0-5](?:\.\d)?(?:\s*\([\d,]+\))?/, "")
    .replace(/rating:\s*[0-5](?:\.\d+)?/i, "")
    .replace(/(\s*·\s*){2,}/g, " · ")
    .replace(/^\s*·\s*|\s*·\s*$/g, "")
    .trim();
}

function resultCard(item, app, opts) {
  opts = opts || {};
  var h = item.hit;
  var key = (opts.prefix || "hit") + "_" + item.service + "_" + item.index;
  var meta = [priceText(h), ratingTag(h), opts.hideSource ? null : sourceTag(item)].filter(Boolean);
  var detail = detailText(h);
  var tap = app.handler("open_" + key, function () { openItem(item); });
  var titleNode = { type: "Markdown", props: { text: linkTitle(h.title, h.url), size: "compact" } };

  if (opts.shape === "tile") {
    return { type: "Card", key: key, props: { variant: "filled", radius: 24, style: { padding: "10", gap: "10" } }, events: { tap: tap }, children: [
      picture(item, { ratio: 4 / 3, radius: 18 }),
      { type: "Column", props: { style: { padding: "0 4 4 4", gap: "6", alignItems: "stretch" } }, children: [
        titleNode,
        detail ? T(detail, "bodySmall", { color: "muted", maxLines: 2, overflow: "ellipsis" }) : null,
        meta.length ? { type: "Wrap", props: { style: { gap: "6", alignItems: "center" } }, children: meta } : null,
      ].filter(Boolean) },
    ] };
  }
  return { type: "Card", key: key, props: { variant: "filled", radius: 20, style: { padding: "10" } }, events: { tap: tap }, children: [
    { type: "Row", props: { style: { gap: "12", alignItems: "flex-start" } }, children: [
      picture(item, { size: 84, radius: 14 }),
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "4", alignItems: "stretch" } }, children: [
        titleNode,
        detail ? T(detail, "bodySmall", { color: "muted", maxLines: 2, overflow: "ellipsis" }) : null,
        meta.length ? { type: "Wrap", props: { style: { gap: "6", alignItems: "center" } }, children: meta } : null,
      ].filter(Boolean) }] },
    ] },
  ] };
}

// Cards laid out for the window: a list of rows on phones, a grid of tiles elsewhere.
function cardGrid(items, app, opts) {
  opts = opts || {};
  if (isCompact() && !opts.forceTiles) {
    return { type: "Column", props: { style: { gap: "10", alignItems: "stretch" } }, children: items.map(function (it) { return resultCard(it, app, opts); }) };
  }
  return { type: "ResponsiveGrid", props: { minColumnWidth: opts.minColumnWidth || 220, maxColumns: opts.maxColumns || 4, gap: 14, runGap: 14 },
    children: items.map(function (it) { return resultCard(it, app, Object.assign({}, opts, { shape: "tile" })); }) };
}

// The highlighted cheapest offer.
function dealCard(item, app) {
  var h = item.hit;
  var compact = isCompact();
  var text = { type: "Column", props: { style: { gap: "6", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "6", alignItems: "center" } }, children: [
      { type: "Icon", props: { icon: "local_offer", size: 18 } },
      T("Lowest price found", "labelLarge"),
    ] },
    T(money(h.price_toman), compact ? "headlineSmallEmphasized" : "headlineMediumEmphasized"),
    { type: "Markdown", props: { text: linkTitle(h.title, h.url), size: "compact" } },
    T("on " + item.source, "bodySmall"),
  ] };
  return { type: "Card", key: "deal", props: { tone: "primary", radius: 28, style: { padding: compact ? "14" : "18" } }, events: { tap: app.handler("open_deal", function () { openItem(item); }) }, children: [
    { type: "Row", props: { style: { gap: "16", alignItems: "center" } }, children: [
      picture(item, { size: compact ? 76 : 104, radius: 18 }),
      { type: "Expanded", children: [text] },
    ] },
  ] };
}

/* ---- one result in full ---------------------------------------------- */

function openItem(item) {
  app.set({ item: item, back: app.state.mode, mode: "item" });
}

function itemView(s, app) {
  var item = s.item;
  if (!item) { return homeView(s, app); }
  var h = item.hit;
  var wide = !isCompact();
  var r = ratingOf(h);
  var facts = [];
  if (h.price_toman) { facts.push({ label: "Price", value: money(h.price_toman) }); }
  if (r) { facts.push({ label: "Rating", value: r.value.toFixed(1) + " of 5" + (r.count ? " · " + String(r.count).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + " reviews" : "") }); }
  facts.push({ label: "From", value: item.source });
  var detail = detailText(h);
  var pic = picture(item, { ratio: wide ? 4 / 3 : 16 / 10, radius: 28 });
  var info = { type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: [
    T(h.title, wide ? "headlineMediumEmphasized" : "headlineSmallEmphasized"),
    h.price_toman ? T(money(h.price_toman), "titleLargeEmphasized", { color: "primary" }) : null,
    { type: "Wrap", props: { style: { gap: "8" } }, children: [ratingTag(h), sourceTag(item)].filter(Boolean) },
    detail ? { type: "Card", props: { variant: "filled", radius: 20, style: { padding: "14 16" } }, children: [T(detail, "bodyMedium")] } : null,
    { type: "KeyValue", props: { items: facts, columns: wide ? 2 : 1 } },
    h.url ? { type: "Card", props: { variant: "outlined", radius: 20, style: { padding: "12 16" } }, children: [
      { type: "Row", props: { style: { gap: "10", alignItems: "center" } }, children: [
        { type: "Icon", props: { icon: "open_in_new", size: 20 } },
        { type: "Expanded", children: [{ type: "Markdown", props: { text: "[Open on " + String(item.source).replace(/[\[\]]/g, " ") + "](" + h.url + ")", size: "compact" } }] },
      ] },
    ] } : T("This site gave no link for it.", "bodySmall", { color: "muted" }),
    { type: "Wrap", props: { style: { gap: "8" } }, children: [
      { type: "Button", key: "item_ask", props: { text: "Ask the analyst about it", icon: "auto_awesome", variant: "tonal" },
        events: { tap: app.handler("item_ask", function () { askAbout(item); }) } },
      { type: "Button", key: "item_more", props: { text: "More like this", icon: "search", variant: "outlined" },
        events: { tap: app.handler("item_more", function () { app.set({ q: h.title }); runSearch(h.title); }) } },
    ] },
  ].filter(Boolean) };
  var body = wide
    ? { type: "Row", props: { style: { gap: "32", alignItems: "flex-start" } }, children: [
        { type: "Expanded", props: { flex: 5 }, children: [pic] },
        { type: "Expanded", props: { flex: 6 }, children: [info] },
      ] }
    : { type: "Column", props: { style: { gap: "20", alignItems: "stretch" } }, children: [pic, info] };
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      { type: "Row", props: { style: { padding: "8 12", gap: "8", alignItems: "center" } }, children: [
        { type: "IconButton", key: "item_back", props: { icon: "arrow_back", tooltip: s.back === "chat" ? "Back to the chat" : "Back to the results" },
          events: { tap: app.handler("item_back", function () { app.set({ mode: app.state.back || "results", item: null }); }) } },
        { type: "Expanded", children: [T(item.source, "titleMedium", { maxLines: 1, overflow: "ellipsis" })] },
      ] },
      { type: "Expanded", children: [{ type: "ListView", children: [pageColumn([body], { maxWidth: 1080 })] }] },
    ] },
  ] };
}

function askAbout(item) {
  var h = item.hit;
  var text = "Tell me more about «" + h.title + "» from " + item.source + (h.price_toman ? " (" + money(h.price_toman) + ")" : "") + ": is it a good choice, and what are the alternatives?";
  app.set({ agentic: true, item: null });
  newChat(text);
}
