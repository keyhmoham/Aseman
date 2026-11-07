/* The store: every game on the platform (the official ones and those people
 * made with the Forge), and each game's page — what it is, how it plays and
 * scores, its best players, the rooms hosting it, reviews, and the ways in:
 * practice now or host a room. */

function storeView(s, app) {
  var st = s.store;
  var body;
  if (s.storeError) body = problem(app, "store_retry", s.storeError, loadStore);
  else if (!st) body = { type: "Shimmer", children: [box({ height: "260", borderRadius: "24", backgroundColor: colors().surfaceContainerHighest })] };
  else {
    var q = (s._storeQ || "").toLowerCase();
    var games = st.games.filter(function (g) { return !q || g.title.toLowerCase().indexOf(q) >= 0 || (g.tags || []).join(" ").indexOf(q) >= 0; });
    body = games.length ? { type: "ResponsiveGrid", props: { minColumnWidth: 280, maxColumns: 3, gap: 16 }, children: games.map(function (g) { return storeCard(app, g); }) }
      : empty(app, "store_empty", "search", "No game matches", "Try another word — or forge the game you are looking for.", signedIn() ? "Forge a game" : null, openForgeList);
  }
  return C([topBar(s, app, null), X(page([
    title("Store", "Games for the Arena, each against AI opponents", signedIn() ? { type: "Button", key: "store_forge", props: { text: compact() ? "Forge" : "Forge a game", icon: "auto_awesome", variant: "tonal" }, events: { tap: app.handler("store_forge", openForgeList) } } : null),
    app.input("store_q", "_storeQ", { search: true, hint: "Search games", live: true }),
    body,
  ]))], { gap: "0" });
}

function storeCard(app, g) {
  return { type: "Card", key: hk("store_card", g.slug), props: { variant: "filled", style: { padding: "0" } },
    events: { tap: app.handler(hk("store_card", g.slug), function () { openGame(g.slug); }) },
    children: [C([
      gameArt(g, 110),
      C([
        T(g.tagline, "bodyMedium", { maxLines: 2, overflow: "ellipsis" }),
        R([stars(g.rating.average, 14), T(g.rating.count ? g.rating.average.toFixed(1) + " (" + g.rating.count + ")" : "No reviews yet", "labelSmall", { color: "muted" }), X(T(n(g.plays) + " plays", "labelSmall", { color: "muted", textAlign: "right" }))], { gap: "6" }),
        { type: "Wrap", props: { style: { gap: "6" } }, children: [
          g.official ? { type: "Tag", props: { text: "Official", icon: "verified", status: "info" } } : { type: "Tag", props: { text: "by @" + (g.author || "player"), icon: "construction" } },
          g.status === "testing" ? { type: "Tag", props: { text: "Testing", status: "warning" } } : null,
          { type: "Tag", props: { text: g.mode || "vs AI", variant: "outline" } },
        ].filter(Boolean) },
      ], { gap: "8", padding: "0 16 16 16" }),
    ], { gap: "12" })] };
}

function openGame(slug) {
  push({ name: "game", slug: slug });
  app.set({ game: null, gameError: null, reviewStars: 5, _review: "" });
  loadGame(slug);
}

function loadGame(slug) {
  api("store/" + slug).then(function (g) { app.set({ game: g, gameSettings: defaults(g) }); }).catch(function (e) { app.set({ gameError: errText(e) }); });
}

function gameView(s, app) {
  var g = s.game;
  if (!g) return C([subBar(app, "game", "Game"), X(s.gameError ? box({ padding: "16" }, [problem(app, "game_retry", s.gameError, function () { loadGame(top().slug); })]) : loading())], { gap: "0" });
  var mine = g.my_rating;
  return C([subBar(app, "game", g.title, g.genre + " · v" + g.version), X(page([
    gameArt(g, compact() ? 140 : 180),
    T(g.description, "bodyLarge"),
    signedIn() ? C([].concat(
      settingControls(app, "game_set", g, s.gameSettings || {}, function (k, v) { var st = Object.assign({}, app.state.gameSettings); st[k] = v; app.set({ gameSettings: st }); }),
      [R([
        X({ type: "Button", key: "game_practice", props: { text: "Practice now", icon: "play_arrow", fullWidth: true, size: "m", loading: !!s.launching }, events: { tap: app.handler("game_practice", function () { startMatch(g.slug, null, app.state.gameSettings); }) } }),
        X({ type: "Button", key: "game_host", props: { text: "Host a room", icon: "add", variant: "tonal", fullWidth: true, size: "m" }, events: { tap: app.handler("game_host", function () { hostGame(g); }) } }),
      ], { gap: "10" })]), { gap: "12" }) : signInCard(),
    mine ? card([R([
      X({ type: "Stat", props: { label: "Your rating", value: mine.rating, format: "integer", icon: "trending_up", size: "compact" } }),
      X({ type: "Stat", props: { label: "Rank", value: g.my_rank ? "#" + g.my_rank : "—", size: "compact" } }),
      X({ type: "Stat", props: { label: "Best score", value: mine.best_score, format: "integer", size: "compact" } }),
    ], { gap: "8" })], {}, { tone: "primary" }) : null,
    section("Top players", null, [g.leaders.length ? { type: "Leaderboard", props: { data: g.leaders.map(function (l) { return { name: l.name, value: g.slug === "arena-chess" ? l.rating : l.best_score, subtitle: "@" + l.handle + " · " + l.wins + " wins" }; }), format: "integer", max: 10 } }
      : T("No ranked games yet — the first win takes the top spot.", "bodyMedium", { color: "muted" })]),
    section("Rooms hosting it", plural(g.rooms.length, "room"), [g.rooms.length ? { type: "ListGroup", children: g.rooms.map(function (r) {
      return { type: "ListTile", key: hk("game_room", r.id), props: { title: r.name, subtitle: (r.theme_info || {}).title + " · " + r.members + "/" + r.max_members + " · @" + r.host, leading: "groups", trailing: "chevron_right" },
        events: { tap: app.handler(hk("game_room", r.id), function () { openRoom(r.id); }) } }; }) }
      : T("No room hosts it yet.", "bodyMedium", { color: "muted" })]),
    section("How it plays", null, [card([
      g.scoring ? C([T("Scoring", "labelLarge"), T(g.scoring, "bodyMedium")], { gap: "4" }) : null,
      (g.controls || []).length ? C([T("Controls", "labelLarge")].concat(g.controls.map(function (c) { return T("· " + c, "bodyMedium"); })), { gap: "4" }) : null,
      (g.credits || []).length ? C([T("Credits", "labelLarge")].concat(g.credits.map(function (c) { return T(c.what + " — " + c.who + " (" + c.license + ")", "bodySmall", { color: "muted" }); })), { gap: "4" }) : null,
    ])]),
    section("Reviews", g.rating.count ? g.rating.average.toFixed(1) + " average · " + g.rating.count : null, [
      signedIn() ? card([
        R([T("Your review", "labelLarge"), X(R([{ type: "Rating", key: "review_stars", props: { value: s.reviewStars || 5, max: 5, size: 22 }, events: { change: app.handler("review_stars", function (e) { app.set({ reviewStars: Math.round(e.value) }); }) } }], { justifyContent: "flex-end" }))]),
        app.input("review_text", "_review", { hint: "What did you think?", multiline: true, live: true }),
        { type: "Button", key: "review_send", props: { text: "Post review", icon: "send", variant: "tonal", disabled: !(s._review || "").trim() }, events: { tap: app.handler("review_send", postReview) } },
      ]) : null,
      g.reviews.length ? { type: "ListGroup", children: g.reviews.map(function (r) {
        return { type: "ListTile", key: hk("review", r.handle), props: { title: r.name + " · " + "★★★★★".slice(0, r.stars), subtitle: r.text || "—", leadingAvatar: r.name, lines: 3, trailingText: ago(r.at) } }; }) } : null,
    ]),
  ]))], { gap: "0" });
}

function hostGame(g) {
  openNewRoom();
  app.set({ draft: Object.assign({}, app.state.draft, { game: g.slug, settings: Object.assign({}, app.state.gameSettings || defaults(g)), visibility: g.status === "testing" ? "private" : "public" }), _roomName: g.title + " night" });
}

function postReview() {
  var g = app.state.game;
  apiPost("store/" + g.slug + "/reviews", { stars: app.state.reviewStars || 5, text: app.state._review }).then(function () {
    app.set({ _review: "", toast: "Thanks for your review" });
    loadGame(g.slug);
  }).catch(function (e) { app.fail(e); });
}
