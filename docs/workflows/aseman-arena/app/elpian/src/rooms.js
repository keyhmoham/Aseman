/* Rooms: a grid of 3D rooms to join, opening one's own (bound to a game of
 * the store, in a themed venue), and inside a room: its venue in 3D with the
 * members around the game's stage, the chat, who is there, the room's board,
 * inviting friends and playing the room's game. */

function roomsView(s, app) {
  var rooms = s.rooms;
  var cols = compact() ? 2 : wide() ? 4 : 3;
  var games = (s.store && s.store.games) || [];
  var head = title("Rooms", "Host a game in a 3D room, or join one", signedIn() ? { type: "Button", key: "rooms_new", props: { text: compact() ? "New" : "New room", icon: "add" }, events: { tap: app.handler("rooms_new", function () { openNewRoom(); }) } } : null);
  var filters = C([
    signedIn() ? { type: "SegmentedButton", key: "rooms_filter", props: { selected: s.roomsFilter, segments: [{ value: "all", label: "All rooms", icon: "public" }, { value: "mine", label: "Joined", icon: "groups" }] },
      events: { change: app.handler("rooms_filter", function (e) { app.set({ roomsFilter: e.value, rooms: null }); loadRooms(); }) } } : null,
    games.length ? { type: "Wrap", props: { style: { gap: "8" } }, children: [{ slug: "", title: "Every game" }].concat(games).map(function (g) {
      return { type: "Chip", key: hk("rooms_game", g.slug || "all"), props: { label: g.title, selected: (s.roomsGame || "") === g.slug, variant: "filter" },
        events: { change: app.handler(hk("rooms_game", g.slug || "all"), function () { app.set({ roomsGame: g.slug, rooms: null }); loadRooms(); }) } };
    }) } : null,
  ], { gap: "10" });
  var body;
  if (s.roomsError) body = problem(app, "rooms_retry", s.roomsError, loadRooms);
  else if (!rooms) body = { type: "Shimmer", children: [box({ height: "220", borderRadius: "24", backgroundColor: colors().surfaceContainerHighest })] };
  else if (!rooms.length) body = empty(app, "rooms_empty", "groups", s.roomsFilter === "mine" ? "You have not joined a room" : "No rooms yet", "Open one, pick its game and theme, and invite your friends.", signedIn() ? "Open a room" : null, openNewRoom);
  else body = { type: "GridView", props: { crossAxisCount: cols, childAspectRatio: compact() ? 0.78 : 0.95, style: { gap: "12" }, scrollable: false }, children: rooms.map(function (r) { return roomCard(app, r); }) };
  return C([topBar(s, app, null), X(page([head, filters, body]))], { gap: "0" });
}

function roomCard(app, r) {
  var th = r.theme_info || {};
  var full = r.members >= r.max_members;
  return { type: "Card", key: hk("room", r.id), props: { variant: "filled", style: { padding: "0" } },
    events: { tap: app.handler(hk("room", r.id), function () { openRoom(r.id); }) },
    children: [C([
      box({ height: "86", gradient: { colors: [hex(r.game_accent, th.accent), hex(th.bg, "#0b1020")], begin: "topLeft", end: "bottomRight" }, padding: "10 12" }, [
        C([R([{ type: "Icon", props: { icon: r.visibility === "public" ? "public" : r.visibility === "friends" ? "group" : "lock", size: 16, style: { color: "#ffffffcc" } } },
              X(T(th.title || r.theme, "labelSmall", { style: { color: "#ffffffcc" }, maxLines: 1, overflow: "ellipsis" }))], { gap: "6" }),
           T(r.game_title, "titleSmallEmphasized", { style: { color: "#ffffff" }, maxLines: 1, overflow: "ellipsis" })], { gap: "18" })]),
      C([
        T(r.name, "titleSmallEmphasized", { maxLines: 2, overflow: "ellipsis" }),
        T("by @" + r.host, "labelSmall", { color: "muted", maxLines: 1, overflow: "ellipsis" }),
        R([{ type: "Icon", props: { icon: "group", size: 16 } }, T(r.members + "/" + r.max_members, "labelMedium"),
           r.online ? { type: "Tag", props: { text: r.online + " on", status: "good", dot: true } } : null], { gap: "6" }),
        r.joined ? { type: "Tag", props: { text: "Joined", icon: "check", status: "info" } } : full ? { type: "Tag", props: { text: "Full", status: "warning" } } : null,
      ], { gap: "6", padding: "10 12 12 12" }),
    ], { gap: "0" })] };
}

// --- opening a room -------------------------------------------------------

function openNewRoom() {
  if (!signedIn()) return;
  var games = (app.state.store && app.state.store.games) || [];
  var g = games[0];
  push({ name: "newroom" });
  app.set({ draft: { name: "", game: g ? g.slug : "", theme: "arena", visibility: "public", max_members: 16, settings: g ? defaults(g) : {}, busy: false } });
  if (!games.length) api("store").then(function (st) {
    var first = st.games[0];
    app.set({ store: st, draft: Object.assign({}, app.state.draft, { game: first ? first.slug : "", settings: first ? defaults(first) : {} }) });
  }).catch(function (e) { app.fail(e); });
}

function defaults(g) {
  var out = {};
  Object.keys(g.settings || {}).forEach(function (k) { out[k] = g.settings[k].default; });
  return out;
}

function gameBySlug(slug) {
  var games = (app.state.store && app.state.store.games) || [];
  for (var i = 0; i < games.length; i++) if (games[i].slug === slug) return games[i];
  return null;
}

function settingControls(app, prefix, g, values, onChange) {
  return Object.keys((g && g.settings) || {}).map(function (k) {
    var spec = g.settings[k], v = values[k] == null ? spec.default : values[k];
    if (spec.type === "integer") {
      return C([R([X(T(spec.label || k, "labelLarge")), T(String(v), "titleSmallEmphasized")]),
        { type: "Slider", key: prefix + "_" + k, props: { value: Number(v), min: spec.min, max: spec.max, divisions: spec.max - spec.min, label: true },
          events: { change: app.handler(prefix + "_" + k, function (e) { onChange(k, Math.round(e.value)); }) } }], { gap: "2" });
    }
    return C([T(spec.label || k, "labelLarge"), { type: "Wrap", props: { style: { gap: "8" } }, children: (spec.values || []).map(function (opt) {
      return { type: "Chip", key: hk(prefix + "_" + k, opt), props: { label: opt, selected: v === opt, variant: "filter" },
        events: { change: app.handler(hk(prefix + "_" + k, opt), function () { onChange(k, opt); }) } };
    }) }], { gap: "6" });
  });
}

function newRoomView(s, app) {
  var d = s.draft || {}, games = (s.store && s.store.games) || [], g = gameBySlug(d.game);
  var themes = s.cfg.room_themes || {};
  function patch(p) { app.set({ draft: Object.assign({}, app.state.draft, p) }); }
  return C([subBar(app, "newroom", "Open a room", "Bound to one game, in a 3D venue"),
    X(page([
      app.input("newroom_name", "_roomName", { label: "Room name", hint: "Friday night chess", icon: "edit", live: true }),
      section("Game", null, [{ type: "Wrap", props: { style: { gap: "8" } }, children: games.map(function (x) {
        return { type: "Chip", key: hk("newroom_game", x.slug), props: { label: x.title + (x.status === "testing" ? " (testing)" : ""), selected: d.game === x.slug, variant: "filter" },
          events: { change: app.handler(hk("newroom_game", x.slug), function () { patch({ game: x.slug, settings: defaults(x), visibility: x.status === "testing" ? "private" : d.visibility }); }) } };
      }) }]),
      section("Venue", "how the room looks in 3D", [{ type: "Wrap", props: { style: { gap: "8" } }, children: Object.keys(themes).map(function (k) {
        return { type: "Chip", key: hk("newroom_theme", k), props: { label: themes[k].title, selected: d.theme === k, variant: "filter" },
          events: { change: app.handler(hk("newroom_theme", k), function () { patch({ theme: k }); }) } };
      }) }]),
      section("Who can join", null, [{ type: "SegmentedButton", key: "newroom_vis", props: { selected: d.visibility, segments: [
        { value: "public", label: "Everyone", icon: "public" }, { value: "friends", label: "Friends", icon: "group" }, { value: "private", label: "Invited", icon: "lock" }] },
        events: { change: app.handler("newroom_vis", function (e) { patch({ visibility: e.value }); }) } }]),
      g ? section("Game settings", "players can change them for their own match", settingControls(app, "newroom_set", g, d.settings || {}, function (k, v) {
        var st = Object.assign({}, app.state.draft.settings); st[k] = v; patch({ settings: st }); })) : null,
      { type: "Button", key: "newroom_create", props: { text: "Open the room", loading: !!d.busy, disabled: !(s._roomName || "").trim() || !d.game, fullWidth: true, size: "m" },
        events: { tap: app.handler("newroom_create", createRoom) } },
    ])),
  ], { gap: "0" });
}

function createRoom() {
  var d = app.state.draft;
  app.set({ draft: Object.assign({}, d, { busy: true }) });
  apiPost("rooms", { name: app.state._roomName, game: d.game, theme: d.theme, visibility: d.visibility, settings: d.settings, max_members: d.max_members })
    .then(function (r) {
      app.set({ _roomName: "", draft: null, rooms: null });
      replace({ name: "room", id: r.id });
      showRoom(r);
    })
    .catch(function (e) { app.set({ draft: Object.assign({}, app.state.draft, { busy: false }) }); app.fail(e); });
}

// --- inside a room -------------------------------------------------------

function openRoom(id) {
  push({ name: "room", id: id });
  app.set({ room: null, roomMsgs: [], roomTab: 0, roomError: null });
  loadRoom(id);
}

function loadRoom(id) {
  api("rooms/" + id).then(showRoom).catch(function (e) { app.set({ roomError: errText(e) }); });
}

function showRoom(r) {
  app.set({ room: r, roomScene: roomScene(r, (app.state.cfg || {}).asset_base || "") });
  pollRoom();
}

function pollRoom() {
  var r = app.state.room;
  if (!r) return;
  var msgs = app.state.roomMsgs || [], after = msgs.length ? msgs[msgs.length - 1].id : 0;
  api("rooms/" + r.id + "/messages?after=" + after).then(function (out) {
    if (!app.state.room || app.state.room.id !== r.id) return;
    if (out.messages.length) app.set({ roomMsgs: (app.state.roomMsgs || []).concat(out.messages).slice(-150) });
  }).catch(function () {});
}

function roomView(s, app) {
  var r = s.room;
  if (!r) return C([subBar(app, "room", "Room"), X(s.roomError ? box({ padding: "16" }, [problem(app, "room_retry", s.roomError, function () { loadRoom(top().id); })]) : loading("Entering the room…"))], { gap: "0" });
  var actions = [];
  if (r.joined) actions.push({ type: "IconButton", key: "room_invite", props: { icon: "person_add", tooltip: "Invite a friend" }, events: { tap: app.handler("room_invite", function () { app.set({ roomTab: 1, inviting: true }); }) } });
  if (r.joined && !r.is_host) actions.push({ type: "IconButton", key: "room_leave", props: { icon: "logout", tooltip: "Leave the room" }, events: { tap: app.handler("room_leave", leaveRoom) } });
  if (r.is_host) actions.push({ type: "IconButton", key: "room_close", props: { icon: "delete", tooltip: "Close the room" }, events: { tap: app.handler("room_close", closeRoom) } });
  var scene = { type: "Scene3D", key: "room_scene", props: { scene: s.roomScene }, children: [roomPlaceholder(r)] };
  var cta = !signedIn() ? signInCard()
    : !r.joined ? { type: "Button", key: "room_join", props: { text: r.members >= r.max_members ? "Room is full" : "Join the room", icon: "group_add", disabled: r.members >= r.max_members, fullWidth: true, size: "m", loading: !!s.joining }, events: { tap: app.handler("room_join", joinRoom) } }
    : { type: "Button", key: "room_play", props: { text: "Play " + r.game_title, icon: "play_arrow", fullWidth: true, size: "m", loading: !!s.launching }, events: { tap: app.handler("room_play", function () { startMatch(r.game, r.id, {}); }) } };
  var tabs = { type: "Tabs", key: "room_tabs", props: { selected: s.roomTab || 0, tabs: [{ label: "Chat", icon: "forum" }, { label: "Players", icon: "group", badge: String(r.members) }, { label: "Board", icon: "emoji_events" }] },
    events: { change: app.handler("room_tabs", function (e) { app.set({ roomTab: e.value }); }) },
    children: [roomChat(s, app, r), roomPlayers(s, app, r), roomBoard(s, app, r)] };
  var side = C([box({ padding: "0 16" }, [cta]), X(tabs)], { gap: "10", alignItems: "stretch" });
  var bar = subBar(app, "room", r.name, r.game_title + " · " + (r.theme_info || {}).title + " · " + r.members + "/" + r.max_members, actions);
  if (wide()) return C([bar, X(R([X(scene, 3), box({ width: "380" }, [side])], { alignItems: "stretch", gap: "0" }))], { gap: "0" });
  return C([bar, box({ height: compact() ? "220" : "300" }, [scene]), X(side)], { gap: "8" });
}

function roomPlaceholder(r) {
  var th = r.theme_info || {};
  return box({ gradient: { colors: [hex(r.game_accent, th.accent), hex(th.bg, "#0b1020")], begin: "topLeft", end: "bottomRight" }, padding: "16", alignItems: "center", justifyContent: "center" }, [
    C([T(r.game_title, "headlineSmallEmphasized", { style: { color: "#ffffff" }, textAlign: "center" }), T(th.title + " · " + plural(r.members, "player"), "bodyMedium", { style: { color: "#ffffffbb" }, textAlign: "center" })], { alignItems: "center", gap: "4" })]);
}

function roomChat(s, app, r) {
  var msgs = s.roomMsgs || [];
  var list = msgs.length ? { type: "ListView", key: "room_msgs", children: msgs.map(function (m) {
    if (m.kind !== "chat") return box({ padding: "4 16" }, [R([{ type: "Icon", props: { icon: m.kind === "result" ? "emoji_events" : "info", size: 16 } }, X(T(m.text, "labelMedium", { color: "muted" })), T(ago(m.at), "labelSmall", { color: "muted" })], { gap: "8" })]);
    return box({ padding: "6 16" }, [R([avatar(m, 28), X(C([R([T(m.name, "labelLarge"), T(ago(m.at), "labelSmall", { color: "muted" })], { gap: "8" }), T(m.text, "bodyMedium")], { gap: "2" }))], { alignItems: "flex-start", gap: "10" })]);
  }) } : C([T("No messages yet — say hello.", "bodyMedium", { color: "muted", textAlign: "center" })], { padding: "24" });
  var composer = r.joined ? R([X(app.input("room_text", "_roomText", { hint: "Message the room", icon: "chat", live: true })),
    { type: "IconButton", key: "room_send", props: { icon: "send", variant: "filled", tooltip: "Send", disabled: !(s._roomText || "").trim() }, events: { tap: app.handler("room_send", sendRoomMessage) } }], { padding: "8 12", gap: "8" }) : null;
  return C([X(list), composer], { gap: "0" });
}

function sendRoomMessage() {
  var r = app.state.room, text = (app.state._roomText || "").trim();
  if (!r || !text) return;
  app.set({ _roomText: "" });
  apiPost("rooms/" + r.id + "/messages", { text: text }).then(function () { pollRoom(); }).catch(function (e) { app.fail(e); });
}

function roomPlayers(s, app, r) {
  var friends = ((s.social || {}).friends || {}).friends || [];
  var inside = {};
  (r.member_list || []).forEach(function (m) { inside[m.handle] = true; });
  var invitable = friends.filter(function (f) { return !inside[f.handle]; });
  return { type: "ListView", children: [C([
    { type: "ListGroup", children: (r.member_list || []).map(function (m) { return playerTile(app, hk("room_member", m.handle), m, m.role === "host" ? "host" : (m.online ? "online" : "")); }) },
    r.joined ? section("Invite friends", invitable.length ? null : "", invitable.length ? [{ type: "ListGroup", children: invitable.map(function (f) {
      return { type: "ListTile", key: hk("room_inv", f.handle), props: { title: f.name, subtitle: "@" + f.handle, leadingAvatar: f.name, trailing: "person_add" },
        events: { tap: app.handler(hk("room_inv", f.handle), function () { invite(f.handle); }) } }; }) }]
      : [T(friends.length ? "Every friend is already here." : "Add friends in Social to invite them.", "bodyMedium", { color: "muted" })]) : null,
  ], { padding: "12 16", gap: "16" })] };
}

function roomBoard(s, app, r) {
  var rows = r.board || [];
  return { type: "ListView", children: [C([
    rows.length ? { type: "Leaderboard", props: { data: rows.map(function (b) { return { name: b.name, value: b.best, subtitle: b.wins + " wins · " + b.games + " games" }; }), format: "integer", highlight: ((s.cfg || {}).me || {}).name } }
      : T("Nobody has played here yet. Be the first on the board.", "bodyMedium", { color: "muted" }),
    r.description ? card([T(r.description, "bodyMedium")]) : null,
  ], { padding: "12 16", gap: "12" })] };
}

function joinRoom() {
  var r = app.state.room;
  app.set({ joining: true });
  apiPost("rooms/" + r.id + "/join").then(function (out) { app.set({ joining: false }); showRoom(out); })
    .catch(function (e) { app.set({ joining: false }); app.fail(e); });
}

function leaveRoom() {
  var r = app.state.room;
  apiPost("rooms/" + r.id + "/leave").then(function () { app.set({ room: null, rooms: null }); back(); }).catch(function (e) { app.fail(e); });
}

function closeRoom() {
  var r = app.state.room;
  apiDelete("rooms/" + r.id).then(function () { app.set({ room: null, rooms: null }); back(); }).catch(function (e) { app.fail(e); });
}

function invite(handle) {
  var r = app.state.room;
  apiPost("rooms/" + r.id + "/invite", { handle: handle }).then(function () { app.set({ toast: "Invited @" + handle }); }).catch(function (e) { app.fail(e); });
}
