/* Talking to the Arena server (Aseman.fetch reaches it through the
 * platform's gateway, which names the signed-in person). */

function api(path, opts) {
  return Aseman.fetch("api/" + path, opts || {}).then(function (r) { return r.json; });
}
function apiPost(path, body) { return api(path, { method: "POST", body: body || {} }); }
function apiPatch(path, body) { return api(path, { method: "PATCH", body: body || {} }); }
function apiPut(path, body) { return api(path, { method: "PUT", body: body || {} }); }
function apiDelete(path) { return api(path, { method: "DELETE" }); }

function errText(e) {
  if (!e) return "Something went wrong";
  var j = e.json || (e.response && e.response.json);
  if (j && j.error) return j.error;
  if (e.status === 0 || /network|fetch/i.test(String(e.message || ""))) return "The Arena is not reachable right now.";
  return String(e.message || e.error || e);
}

function signedIn() { return !!(app.state.cfg && app.state.cfg.signed_in); }

// --- loading what each screen shows -------------------------------------

function boot() {
  // Called from init, before App.create has returned: nothing synchronous
  // may touch the global app here.
  api("config").then(function (cfg) {
    app.set({ cfg: cfg, booted: true, bootError: null });
    loadTab(app.state.tab);
  }).catch(function (e) { app.set({ bootError: errText(e) }); });
}

function loadTab(tab) {
  if (tab === "garage") loadGarage();
  else if (tab === "rooms") loadRooms();
  else if (tab === "store") loadStore();
  else if (tab === "ranks") loadBoard();
  else if (tab === "social") loadSocial();
}

function loadGarage() {
  if (!signedIn()) { loadStore(); return; }
  api("garage").then(function (g) {
    var games = (app.state.store && app.state.store.games) || [];
    app.set({ garage: g, garageScene: garageScene(g, games), unread: g.unread });
    if (!app.state.store) api("store").then(function (st) { app.set({ store: st, garageScene: garageScene(g, st.games) }); }).catch(function () {});
  }).catch(function (e) { app.set({ garageError: errText(e) }); });
}

function loadRooms() {
  var s = app.state;
  api("rooms?filter=" + s.roomsFilter + (s.roomsGame ? "&game=" + s.roomsGame : "")).then(function (r) { app.set({ rooms: r.rooms, roomsError: null }); })
    .catch(function (e) { app.set({ roomsError: errText(e) }); });
  if (!s.store) api("store").then(function (st) { app.set({ store: st }); }).catch(function () {});
}

function loadStore() {
  api("store").then(function (st) { app.set({ store: st, storeError: null }); }).catch(function (e) { app.set({ storeError: errText(e) }); });
}

function loadBoard() {
  var s = app.state;
  api("leaderboard?game=" + (s.boardGame || "") + "&period=" + s.boardPeriod).then(function (b) { app.set({ board: b, boardError: null }); })
    .catch(function (e) { app.set({ boardError: errText(e) }); });
  if (!s.store) api("store").then(function (st) { app.set({ store: st }); }).catch(function () {});
}

function loadSocial() {
  if (!signedIn()) return;
  Aseman.Task.all([api("friends"), api("messages"), api("notifications")]).then(function (r) {
    app.set({ social: { friends: r[0], threads: r[1].threads, notes: r[2].notifications }, unread: r[2].unread, socialError: null });
  }).catch(function (e) { app.set({ socialError: errText(e) }); });
}

function refreshUnread() {
  if (!signedIn()) return;
  api("notifications").then(function (r) { app.set({ unread: r.unread }); }).catch(function () {});
}
