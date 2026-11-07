/* Aseman Arena — the app: five destinations (garage, rooms, store,
 * leaderboards, social), a stack of screens over them (a room, a game's
 * page, a match, a profile, a conversation, the Forge), live updates, and
 * the phone widget (level, rating, what friends are up to). */

var TABS = [
  { id: "garage", label: "Garage", icon: "home" },
  { id: "rooms", label: "Rooms", icon: "groups" },
  { id: "store", label: "Store", icon: "storefront" },
  { id: "ranks", label: "Ranks", icon: "emoji_events" },
  { id: "social", label: "Social", icon: "forum" },
];

var app = App.create({
  state: {
    booted: false, bootError: null, cfg: null, tab: "garage", stack: [], toast: null, unread: null,
    garage: null, garageScene: null, garageError: null,
    rooms: null, roomsFilter: "all", roomsGame: "", roomsError: null,
    store: null, storeError: null, game: null, gameError: null, gameSettings: {},
    board: null, boardGame: "", boardPeriod: "all", boardError: null,
    social: null, socialTab: 0, socialError: null, found: [],
    room: null, roomScene: null, roomMsgs: [], roomTab: 0, roomError: null, draft: null,
    play: null, launching: false, profile: null, dm: null, forge: null, forgeList: null,
  },

  view: function (s, app) {
    if (!s.booted) {
      if (s.bootError) return { type: "Scaffold", children: [box({ padding: "24" }, [C([
        { type: "Callout", props: { severity: "critical", title: "The Arena is not reachable", text: s.bootError } },
        { type: "Button", key: "boot_retry", props: { text: "Try again", icon: "refresh", variant: "tonal" }, events: { tap: app.handler("boot_retry", function (e, app) { app.set({ bootError: null }); boot(); }) } }], { gap: "12" })])] };
      return { type: "Scaffold", children: [loading("Opening the Arena…")] };
    }
    var screen = top();
    var body;
    if (screen) body = ({ room: roomView, newroom: newRoomView, play: playView, game: gameView, profile: profileView, dm: dmView, forgelist: forgeListView, forge: forgeView }[screen.name] || garageView)(s, app);
    else body = ({ garage: garageView, rooms: roomsView, store: storeView, ranks: ranksView, social: socialView }[s.tab])(s, app);
    var children = [s.toast ? { type: "Stack", children: [body, { type: "Positioned", props: { style: { left: "16", right: "16", bottom: "12" } }, children: [
      { type: "Callout", key: "toast", props: { severity: "good", title: s.toast } }] }] } : body];
    if (!screen) children.push({ type: "NavigationBar", key: "nav", props: { selected: tabIndex(s.tab), items: TABS.map(function (t) {
      var badge = t.id === "social" && s.unread ? (s.unread.notifications || 0) + (s.unread.messages || 0) : 0;
      return { icon: t.icon, label: t.label, badge: badge ? String(badge) : undefined };
    }) }, events: { change: app.handler("nav", function (e) { go(TABS[e.value].id); }) } });
    return { type: "Scaffold", children: children };
  },

  init: function (app) {
    boot();
    app.every("live", 5000, tick);
  },

  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 60000,
    refresh: function () { boot(); },
    view: function (s) {
      var size = (Aseman.env().widget || {}).size || "medium";
      if (!s.booted || !s.cfg) return { type: "Shimmer", children: [box({ height: "52", borderRadius: "16", backgroundColor: colors().surfaceContainerHighest })] };
      var me = s.cfg.me;
      if (!me) return R([X(C([T(s.cfg.product, "titleSmallEmphasized"), T("Sign in to play", "bodySmall", { color: "muted" })], { gap: "2" }))], { padding: "14" });
      var u = s.unread || s.cfg.unread || {};
      return R([
        X({ type: "Stat", props: { label: me.name, value: "Level " + me.progress.level, icon: "sports_esports", size: "compact" } }),
        size === "small" ? null : C([
          { type: "Tag", props: { text: me.wins + " wins · streak " + me.streak, status: me.streak >= 3 ? "good" : "info" } },
          { type: "Progress", props: { value: me.progress.span ? me.progress.into / me.progress.span : 0, showValue: false, thickness: 6 } },
          (u.notifications || u.messages) ? { type: "Tag", props: { text: ((u.notifications || 0) + (u.messages || 0)) + " new", status: "warning" } } : null,
        ], { gap: "6" }),
      ], { padding: "14" });
    },
  },
});

// --- navigation ---------------------------------------------------------------

function tabIndex(id) { for (var i = 0; i < TABS.length; i++) if (TABS[i].id === id) return i; return 0; }
function top() { var st = app.state.stack; return st.length ? st[st.length - 1] : null; }
function push(screen) { app.set({ stack: app.state.stack.concat([screen]) }); }
function replace(screen) { var st = app.state.stack.slice(0, -1); app.set({ stack: st.concat([screen]) }); }
function back() {
  var st = app.state.stack.slice(0, -1);
  app.set({ stack: st });
  // What the person returns to is shown as it is now.
  var t = st.length ? st[st.length - 1] : null;
  if (!t) loadTab(app.state.tab);
  else if (t.name === "forgelist") loadForgeList();
  else if (t.name === "room") loadRoom(t.id);
  else if (t.name === "game") loadGame(t.slug);
  else if (t.name === "profile") loadProfile(t.handle);
}
function go(tab) {
  app.set({ tab: tab, stack: [] });
  loadTab(tab);
}

// --- live updates every 5 s ------------------------------------------------------

var ticks = 0;
function tick() {
  if (!app.state.booted || app.isWidget()) return;
  ticks++;
  var t = top();
  if (t && t.name === "room") { pollRoom(); if (ticks % 6 === 0 && app.state.room) loadRoom(app.state.room.id); }
  else if (t && t.name === "dm") loadDM(t.handle);
  else if (t && t.name === "forge" && (forgeThinking(app.state.forge) || ticks % 4 === 0)) loadForge(t.id);
  else if (!t && app.state.tab === "rooms" && ticks % 3 === 0) loadRooms();
  if (app.state.toast && ticks % 1 === 0) app.set({ toast: null });
  if (ticks % 6 === 0) refreshUnread();
}
