/* The garage: the person's 3D home (a workshop garage or a research lab),
 * where they land. The room fills the screen; below it, who they are, where
 * their friends are playing, and the way into rooms, the store and the Forge. */

function garageView(s, app) {
  if (!signedIn()) return welcomeView(s, app);
  var g = s.garage;
  if (!g) return C([topBar(s, app, "Your garage"), s.garageError ? problem(app, "garage_retry", s.garageError, loadGarage) : loading("Opening your garage…")], { gap: "0" });
  var me = g.me || {};
  var scene = {
    type: "Scene3D", key: "garage_scene", props: { scene: s.garageScene },
    events: { asseterror: app.handler("garage_asset_err", function (e) { Aseman.log("asset", e.id, e.message); }) },
    children: [garagePlaceholder(g)],
  };
  var panel = C([
    R([avatar(me, 44), X(C([T(me.name, "titleMediumEmphasized", { maxLines: 1, overflow: "ellipsis" }), T("@" + me.handle + (me.title ? " · " + me.title : ""), "labelMedium", { color: "muted", maxLines: 1, overflow: "ellipsis" })], { gap: "2" })),
       { type: "SegmentedButton", key: "garage_theme", props: { size: "s", selected: g.theme, segments: [{ value: "garage", label: "Garage", icon: "handyman" }, { value: "lab", label: "Lab", icon: "biotech" }] },
         events: { change: app.handler("garage_theme", function (e) { switchGarage(e.value); }) } }]),
    levelBar(me.progress),
    R([
      X({ type: "Button", key: "garage_rooms", props: { text: "Rooms", icon: "groups", fullWidth: true }, events: { tap: app.handler("garage_rooms", function () { go("rooms"); }) } }),
      X({ type: "Button", key: "garage_forge", props: { text: "Forge a game", icon: "auto_awesome", variant: "tonal", fullWidth: true }, events: { tap: app.handler("garage_forge", function () { openForgeList(); }) } }),
    ], { gap: "10" }),
  ], { gap: "12", padding: "14 16 12 16" });
  if (wide()) {
    return R([X(scene, 3), box({ width: "340" }, [{ type: "ListView", children: [panel, garageExtras(s, app)] }])], { alignItems: "stretch", gap: "0" });
  }
  return C([topBar(s, app, me.progress ? "Level " + me.progress.level : "Your garage"), X(scene), panel], { gap: "0", alignItems: "stretch" });
}

function garagePlaceholder(g) {
  var me = g.me || {};
  return box({ gradient: { colors: [g.layout.shell.bg, "#2a2f3c"], begin: "topCenter", end: "bottomCenter" }, padding: "20", alignItems: "center", justifyContent: "center" }, [
    C([{ type: "Icon", props: { icon: g.theme === "lab" ? "biotech" : "handyman", size: 40, style: { color: "#ffffffcc" } } },
       T(g.layout.title, "titleLargeEmphasized", { style: { color: "#ffffff" }, textAlign: "center" }),
       T((g.trophies || []).length + " trophies on the shelf · level " + ((me.progress || {}).level || 1), "bodyMedium", { style: { color: "#ffffffaa" }, textAlign: "center" })],
      { alignItems: "center", gap: "6" })]);
}

function garageExtras(s, app) {
  var g = s.garage, trophies = g.trophies || [];
  return C([
    section("Trophies", trophies.length + " of " + Object.keys(s.cfg.achievements || {}).length, [
      trophies.length ? { type: "Wrap", props: { style: { gap: "8" } }, children: trophies.map(function (t) {
        return { type: "Chip", key: hk("trophy", t.id), props: { label: t.title, icon: t.icon } }; }) }
        : T("Win your first match to put a trophy on the shelf.", "bodyMedium", { color: "muted" }),
    ]),
  ], { padding: "0 16 16 16", gap: "16" });
}

function switchGarage(theme) {
  apiPut("garage", { theme: theme }).then(function (g) {
    app.set({ garage: g, garageScene: garageScene(g, (app.state.store || {}).games) });
  }).catch(function (e) { app.fail(e); });
}

/* The top bar of the main destinations: the product, notifications and the
 * person's profile. */
function topBar(s, app, sub) {
  var u = s.unread || (s.cfg && s.cfg.unread) || {};
  var count = (u.notifications || 0) + (u.messages || 0);
  var me = s.cfg && s.cfg.me;
  return R([
    X(C([T(s.cfg ? s.cfg.product : "Arena", "titleLargeEmphasized"), sub ? T(sub, "labelMedium", { color: "muted" }) : null], { gap: "0" })),
    signedIn() ? { type: "Badge", props: count ? { count: count } : { label: "" }, children: [
      { type: "IconButton", key: "top_alerts", props: { icon: "notifications", tooltip: "Notifications" }, events: { tap: app.handler("top_alerts", function () { go("social"); app.set({ socialTab: 2 }); }) } }] } : null,
    signedIn() && me ? { type: "IconButton", key: "top_me", props: { icon: "person", tooltip: "Your profile" }, events: { tap: app.handler("top_me", function () { openProfile(me.handle); }) } } : null,
  ], { padding: "10 12 6 16", gap: "4" });
}

/* Visitors: what the Arena is, its games and the best players. */
function welcomeView(s, app) {
  var games = (s.store && s.store.games) || [];
  return page([
    box({ gradient: { colors: ["#1b2a4a", "#0b1020"], begin: "topLeft", end: "bottomRight" }, padding: "24", borderRadius: "28" }, [C([
      T(s.cfg.product, "displaySmallEmphasized", { style: { color: "#ffffff" } }),
      T("Your own 3D garage, rooms to host games in, AI opponents that fight back, leaderboards, friends — and a Forge where an AI builds the game you describe.", "bodyLarge", { style: { color: "#ffffffcc" } }),
    ], { gap: "10" })]),
    signInCard(),
    section("Games in the store", plural(games.length, "game"), games.map(function (g) {
      return { type: "Card", key: hk("welcome_game", g.slug), props: { variant: "filled", style: { padding: "0" } }, events: { tap: app.handler(hk("welcome_game", g.slug), function () { openGame(g.slug); }) },
        children: [C([gameArt(g, 88), box({ padding: "0 16 14 16" }, [T(g.tagline, "bodyMedium", { color: "muted" })])], { gap: "10" })] };
    })),
  ]);
}
